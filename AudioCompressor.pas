(*
 * MIT License
 *
 * Copyright (c) 2025 Matthew Abbott
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *)

program AudioCompressor;

{
  High-Quality Audio Compressor - Pascal Implementation
}

{$MODE OBJFPC}
{$MODESWITCH ADVANCEDRECORDS}

uses
  SysUtils, Math, Classes;

const
  PI = 3.14159265358979323846;
  TWO_PI = 6.28318530717958647693;
  MAX_CHANNELS = 2;
  MAX_SAMPLES_PER_BLOCK = 4096;
  
type
  TStereoLinkMode = (slmIndependent, slmAverage, slmMax, slmRMS, slmMidSide);
  TEnvelopeMode = (emPeak, emRMS, emTrueRMS, emAdaptive);
  TReleaseCurve = (rcLinear, rcExponential, rcAdaptive);
  
  PPCMSamples = ^TPCMSamples;
  TPCMSamples = array of array of Double;

  TCompressorParams = record
    Threshold: Double;
    Ratio: Double;
    AttackMS: Double;
    ReleaseMS: Double;
    KneeDB: Double;
    MakeupGain: Double;
    StereoLinkMode: TStereoLinkMode;
    EnvelopeMode: TEnvelopeMode;
    ReleaseCurve: TReleaseCurve;
    LookaheadMS: Double;
    MixDry: Double;
    Bypass: Boolean;
  end;

  TBlockMetrics = record
    InputPeak: Double;
    InputRMS: Double;
    OutputPeak: Double;
    OutputRMS: Double;
    GainReductionPeak: Double;
    GainReductionRMS: Double;
    AvgGainReductionDB: Double;
  end;

  // ============================================================================
  // DSP Math Utilities
  // ============================================================================

  TDSPMath = class
  public
    class function DBToLinear(dB: Double): Double; static;
    class function LinearToDB(linear: Double): Double; static;
    class function MsToSamples(ms: Double; sampleRate: Integer): Integer; static;
    class function SamplesToMs(samples: Integer; sampleRate: Integer): Double; static;
    class function SoftKnee(input, threshold, kneeDB: Double): Double; static;
    class function Lerp(a, b, t: Double): Double; static;
  end;

  // ============================================================================
  // Envelope Detector
  // ============================================================================

  TEnvelopeDetector = class
  private
    FAttackSamples: Integer;
    FReleaseSamples: Integer;
    FCurrentEnvelope: array[0..MAX_CHANNELS-1] of Double;
    FEnvelopeMode: TEnvelopeMode;
    FReleaseCurve: TReleaseCurve;
    FSampleRate: Integer;
    FRMSWindow: Integer;
    FRMSHistory: array[0..MAX_CHANNELS-1] of array of Double;
    FRMSIndex: Integer;
  public
    constructor Create(sampleRate: Integer; attackMS, releaseMS: Double;
                       envMode: TEnvelopeMode; releaseCurve: TReleaseCurve);
    destructor Destroy; override;
    procedure ProcessSample(var input: array of Double; var output: array of Double; numChannels: Integer);
    function GetEnvelope(channel: Integer): Double;
    procedure Reset;
  end;

  // ============================================================================
  // Compressor Core
  // ============================================================================

  TCompressorCore = class
  private
    FParams: TCompressorParams;
    FSampleRate: Integer;
    FNumChannels: Integer;
    FEnvelopeDetector: TEnvelopeDetector;
    FLookaheadBuffer: array[0..MAX_CHANNELS-1] of array of Double;
    FLookaheadSize: Integer;
    FLookaheadIndex: Integer;
    FGainReductionHistory: array of Double;
    FGainReductionIndex: Integer;
  public
    constructor Create(sampleRate: Integer; numChannels: Integer; params: TCompressorParams);
    destructor Destroy; override;
    procedure ProcessBlock(var input: TPCMSamples; var output: TPCMSamples; 
                          numSamples: Integer; var metrics: TBlockMetrics);
    procedure Reset;
  private
    procedure ComputeGainReduction(envInput: Double; var gainReductionDB: Double);
  end;

  // ============================================================================
  // WAV File I/O
  // ============================================================================

  TWAVFile = class
  private
    FFilename: string;
    FSampleRate: Integer;
    FNumChannels: Integer;
    FBitsPerSample: Integer;
    FSamples: TPCMSamples;
    FNumSamples: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    function ReadWAV(filename: string): Boolean;
    function WriteWAV(filename: string): Boolean;
    property SampleRate: Integer read FSampleRate;
    property NumChannels: Integer read FNumChannels;
    property BitsPerSample: Integer read FBitsPerSample;
    property NumSamples: Integer read FNumSamples;
    property Samples: TPCMSamples read FSamples;
  end;

  // ============================================================================
  // Metering
  // ============================================================================

  TMeterRecorder = class
  private
    FMetrics: array of TBlockMetrics;
    FMetricCount: Integer;
    FGainReductionSamples: array of Double;
    FGainReductionCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure RecordMetrics(metrics: TBlockMetrics);
    procedure RecordGainReduction(gainDB: Double);
    procedure ExportCSV(filename: string);
    procedure PrintSummary;
  end;

// ============================================================================
// IMPLEMENTATIONS
// ============================================================================

class function TDSPMath.DBToLinear(dB: Double): Double;
begin
  Result := Power(10, dB / 20);
end;

class function TDSPMath.LinearToDB(linear: Double): Double;
begin
  if linear <= 0 then
    Result := -200
  else
    Result := 20 * Log10(linear);
end;

class function TDSPMath.MsToSamples(ms: Double; sampleRate: Integer): Integer;
begin
  Result := Max(1, Round(ms * sampleRate / 1000));
end;

class function TDSPMath.SamplesToMs(samples: Integer; sampleRate: Integer): Double;
begin
  Result := samples * 1000.0 / sampleRate;
end;

class function TDSPMath.SoftKnee(input, threshold, kneeDB: Double): Double;
var
  kneeHalf: Double;
begin
  if kneeDB <= 0 then
  begin
    if input < threshold then
      Result := 0
    else
      Result := input - threshold;
  end
  else
  begin
    kneeHalf := kneeDB / 2;
    if input < threshold - kneeHalf then
      Result := 0
    else if input < threshold + kneeHalf then
      Result := Sqr(input - (threshold - kneeHalf)) / (2 * kneeDB)
    else
      Result := input - threshold;
  end;
end;

class function TDSPMath.Lerp(a, b, t: Double): Double;
begin
  Result := a + (b - a) * t;
end;

// TEnvelopeDetector Implementation
constructor TEnvelopeDetector.Create(sampleRate: Integer; attackMS, releaseMS: Double;
                                    envMode: TEnvelopeMode; releaseCurve: TReleaseCurve);
var
  i: Integer;
begin
  FSampleRate := sampleRate;
  FAttackSamples := Max(1, Round(attackMS * sampleRate / 1000));
  FReleaseSamples := Max(1, Round(releaseMS * sampleRate / 1000));
  FEnvelopeMode := envMode;
  FReleaseCurve := releaseCurve;
  FRMSWindow := Max(1, sampleRate div 10);
  
  for i := 0 to MAX_CHANNELS-1 do
    FCurrentEnvelope[i] := 0;
  
  FRMSIndex := 0;
  SetLength(FRMSHistory[0], FRMSWindow);
  SetLength(FRMSHistory[1], FRMSWindow);
end;

destructor TEnvelopeDetector.Destroy;
begin
  SetLength(FRMSHistory[0], 0);
  SetLength(FRMSHistory[1], 0);
  inherited;
end;

procedure TEnvelopeDetector.ProcessSample(var input: array of Double; var output: array of Double; numChannels: Integer);
var
  i, ch: Integer;
  target, rate: Double;
  rmsSum: Double;
begin
  for ch := 0 to numChannels - 1 do
  begin
    target := Abs(input[ch]);
    
    if FEnvelopeMode in [emRMS, emTrueRMS] then
    begin
      FRMSHistory[ch][FRMSIndex] := input[ch] * input[ch];
      rmsSum := 0;
      for i := 0 to FRMSWindow - 1 do
        rmsSum := rmsSum + FRMSHistory[ch][i];
      target := Sqrt(rmsSum / FRMSWindow);
    end;
    
    if target > FCurrentEnvelope[ch] then
    begin
      rate := (1.0 - Power(0.01, 1.0 / FAttackSamples));
      FCurrentEnvelope[ch] := FCurrentEnvelope[ch] + rate * (target - FCurrentEnvelope[ch]);
    end
    else
    begin
      if FReleaseCurve = rcLinear then
        rate := 1.0 / FReleaseSamples
      else
        rate := (1.0 - Power(0.01, 1.0 / FReleaseSamples));
      FCurrentEnvelope[ch] := FCurrentEnvelope[ch] - rate * (FCurrentEnvelope[ch] - target);
    end;
    
    output[ch] := FCurrentEnvelope[ch];
  end;
  
  FRMSIndex := (FRMSIndex + 1) mod FRMSWindow;
end;

function TEnvelopeDetector.GetEnvelope(channel: Integer): Double;
begin
  Result := FCurrentEnvelope[channel];
end;

procedure TEnvelopeDetector.Reset;
var
  i: Integer;
begin
  for i := 0 to MAX_CHANNELS - 1 do
    FCurrentEnvelope[i] := 0;
  FRMSIndex := 0;
end;

// TCompressorCore Implementation
constructor TCompressorCore.Create(sampleRate: Integer; numChannels: Integer; params: TCompressorParams);
var
  ch: Integer;
begin
  FSampleRate := sampleRate;
  FNumChannels := numChannels;
  FParams := params;
  
  FEnvelopeDetector := TEnvelopeDetector.Create(sampleRate, params.AttackMS, params.ReleaseMS,
                                                 params.EnvelopeMode, params.ReleaseCurve);
  
  FLookaheadSize := TDSPMath.MsToSamples(params.LookaheadMS, sampleRate);
  FLookaheadIndex := 0;
  
  for ch := 0 to MAX_CHANNELS - 1 do
    SetLength(FLookaheadBuffer[ch], FLookaheadSize + 1);
  
  SetLength(FGainReductionHistory, MAX_SAMPLES_PER_BLOCK);
  FGainReductionIndex := 0;
end;

destructor TCompressorCore.Destroy;
var
  ch: Integer;
begin
  FEnvelopeDetector.Free;
  for ch := 0 to MAX_CHANNELS - 1 do
    SetLength(FLookaheadBuffer[ch], 0);
  SetLength(FGainReductionHistory, 0);
  inherited;
end;

procedure TCompressorCore.ComputeGainReduction(envInput: Double; var gainReductionDB: Double);
var
  inputDB: Double;
  softKneeAmount: Double;
  gainDB: Double;
begin
  if envInput <= 0 then
    inputDB := -200
  else
    inputDB := TDSPMath.LinearToDB(envInput);
  
  gainReductionDB := 0;
  
  softKneeAmount := TDSPMath.SoftKnee(inputDB, FParams.Threshold, FParams.KneeDB);
  
  if softKneeAmount > 0 then
  begin
    if FParams.Ratio >= 100 then
      gainDB := -softKneeAmount
    else
      gainDB := softKneeAmount * (1.0 / FParams.Ratio - 1.0);
    
    gainReductionDB := gainDB;
  end;
end;

procedure TCompressorCore.ProcessBlock(var input: TPCMSamples; var output: TPCMSamples; 
                                      numSamples: Integer; var metrics: TBlockMetrics);
var
  s, ch: Integer;
  envelope: array[0..MAX_CHANNELS-1] of Double;
  envOut: array[0..MAX_CHANNELS-1] of Double;
  gainReductionDB: Double;
  gainLinear: Double;
  linkingEnvelope: Double;
  inputSample, outputSample: Double;
begin
  metrics.InputPeak := 0;
  metrics.InputRMS := 0;
  metrics.OutputPeak := 0;
  metrics.OutputRMS := 0;
  metrics.GainReductionPeak := 0;
  metrics.GainReductionRMS := 0;
  metrics.AvgGainReductionDB := 0;
  
  FGainReductionIndex := 0;
  
  for s := 0 to numSamples - 1 do
  begin
    for ch := 0 to FNumChannels - 1 do
    begin
      envelope[ch] := input[ch][s];
      metrics.InputPeak := Max(metrics.InputPeak, Abs(envelope[ch]));
      metrics.InputRMS := metrics.InputRMS + envelope[ch] * envelope[ch];
      FLookaheadBuffer[ch][FLookaheadIndex] := envelope[ch];
    end;
    
    FEnvelopeDetector.ProcessSample(envelope, envOut, FNumChannels);
    
    linkingEnvelope := envOut[0];
    case FParams.StereoLinkMode of
      slmIndependent: linkingEnvelope := envOut[0];
      slmAverage:
        if FNumChannels = 2 then
          linkingEnvelope := (envOut[0] + envOut[1]) / 2
        else
          linkingEnvelope := envOut[0];
      slmMax:
        if FNumChannels = 2 then
          linkingEnvelope := Max(envOut[0], envOut[1])
        else
          linkingEnvelope := envOut[0];
      slmRMS:
        if FNumChannels = 2 then
          linkingEnvelope := Sqrt((envOut[0]*envOut[0] + envOut[1]*envOut[1]) / 2)
        else
          linkingEnvelope := envOut[0];
    end;
    
    ComputeGainReduction(linkingEnvelope, gainReductionDB);
    FGainReductionHistory[FGainReductionIndex] := gainReductionDB;
    Inc(FGainReductionIndex);
    
    gainLinear := TDSPMath.DBToLinear(gainReductionDB + FParams.MakeupGain);
    metrics.GainReductionPeak := Max(metrics.GainReductionPeak, Abs(gainReductionDB));
    metrics.GainReductionRMS := metrics.GainReductionRMS + gainReductionDB * gainReductionDB;
    
    if not FParams.Bypass then
    begin
      for ch := 0 to FNumChannels - 1 do
      begin
        inputSample := input[ch][s];
        outputSample := inputSample * gainLinear;
        outputSample := TDSPMath.Lerp(outputSample, inputSample, FParams.MixDry);
        output[ch][s] := outputSample;
        
        metrics.OutputPeak := Max(metrics.OutputPeak, Abs(outputSample));
        metrics.OutputRMS := metrics.OutputRMS + outputSample * outputSample;
      end;
    end
    else
    begin
      for ch := 0 to FNumChannels - 1 do
        output[ch][s] := input[ch][s];
    end;
    
    FLookaheadIndex := (FLookaheadIndex + 1) mod (FLookaheadSize + 1);
  end;
  
  metrics.InputRMS := Sqrt(metrics.InputRMS / (numSamples * FNumChannels));
  metrics.OutputRMS := Sqrt(metrics.OutputRMS / (numSamples * FNumChannels));
  metrics.GainReductionRMS := Sqrt(metrics.GainReductionRMS / numSamples);
  
  if FGainReductionIndex > 0 then
  begin
    metrics.AvgGainReductionDB := 0;
    for s := 0 to FGainReductionIndex - 1 do
      metrics.AvgGainReductionDB := metrics.AvgGainReductionDB + FGainReductionHistory[s];
    metrics.AvgGainReductionDB := metrics.AvgGainReductionDB / FGainReductionIndex;
  end;
end;

procedure TCompressorCore.Reset;
begin
  FEnvelopeDetector.Reset;
  FLookaheadIndex := 0;
end;

// TWAVFile Implementation
constructor TWAVFile.Create;
begin
  FSampleRate := 44100;
  FNumChannels := 2;
  FBitsPerSample := 16;
  FNumSamples := 0;
  SetLength(FSamples, MAX_CHANNELS);
end;

destructor TWAVFile.Destroy;
var
  i: Integer;
begin
  for i := 0 to MAX_CHANNELS - 1 do
    SetLength(FSamples[i], 0);
  SetLength(FSamples, 0);
  inherited;
end;

function TWAVFile.ReadWAV(filename: string): Boolean;
var
  f: file;
  bytes: array[0..3] of Byte;
  i, ch, s, sampleCount: Integer;
  sample16: SmallInt;
  sample32: Longint;
  sr, nc, bps: Integer;
  byteRate, blockAlign, dataSize: Integer;
  value: Double;
  b: Byte;
begin
  Result := False;
  if not FileExists(filename) then
    Exit;
  
  AssignFile(f, filename);
  FileMode := 0;
  Reset(f, 1);
  
  try
    // Read RIFF header
    for i := 0 to 3 do
    begin
      BlockRead(f, b, 1);
      bytes[i] := b;
    end;
    if (chr(bytes[0]) <> 'R') or (chr(bytes[1]) <> 'I') or 
       (chr(bytes[2]) <> 'F') or (chr(bytes[3]) <> 'F') then Exit;
    
    // Skip chunk size
    for i := 0 to 3 do
    begin
      BlockRead(f, b, 1);
      bytes[i] := b;
    end;
    
    // Read WAVE
    for i := 0 to 3 do
    begin
      BlockRead(f, b, 1);
      bytes[i] := b;
    end;
    if (chr(bytes[0]) <> 'W') or (chr(bytes[1]) <> 'A') or 
       (chr(bytes[2]) <> 'V') or (chr(bytes[3]) <> 'E') then Exit;
    
    // Find fmt chunk
    repeat
      for i := 0 to 3 do
      begin
        BlockRead(f, b, 1);
        bytes[i] := b;
      end;
    until (chr(bytes[0]) = 'f') and (chr(bytes[1]) = 'm') and 
          (chr(bytes[2]) = 't') and (chr(bytes[3]) = ' ');
    
    // Read fmt size
    for i := 0 to 3 do
    begin
      BlockRead(f, b, 1);
      bytes[i] := b;
    end;
    
    // Read fmt data
    BlockRead(f, b, 1); bytes[0] := b;
    BlockRead(f, b, 1); bytes[1] := b;
    if (bytes[1] <> 0) or (bytes[0] <> 1) then Exit;
    
    BlockRead(f, b, 1); bytes[0] := b;
    BlockRead(f, b, 1); bytes[1] := b;
    nc := bytes[0] or (bytes[1] shl 8);
    
    for i := 0 to 3 do
    begin
      BlockRead(f, b, 1);
      bytes[i] := b;
    end;
    sr := bytes[0] or (bytes[1] shl 8) or (bytes[2] shl 16) or (bytes[3] shl 24);
    
    for i := 0 to 3 do
    begin
      BlockRead(f, b, 1);
      bytes[i] := b;
    end;
    byteRate := bytes[0] or (bytes[1] shl 8) or (bytes[2] shl 16) or (bytes[3] shl 24);
    
    BlockRead(f, b, 1); bytes[0] := b;
    BlockRead(f, b, 1); bytes[1] := b;
    blockAlign := bytes[0] or (bytes[1] shl 8);
    
    BlockRead(f, b, 1); bytes[0] := b;
    BlockRead(f, b, 1); bytes[1] := b;
    bps := bytes[0] or (bytes[1] shl 8);
    
    // Find data chunk
    repeat
      for i := 0 to 3 do
      begin
        BlockRead(f, b, 1);
        bytes[i] := b;
      end;
    until (chr(bytes[0]) = 'd') and (chr(bytes[1]) = 'a') and 
          (chr(bytes[2]) = 't') and (chr(bytes[3]) = 'a');
    
    for i := 0 to 3 do
    begin
      BlockRead(f, b, 1);
      bytes[i] := b;
    end;
    dataSize := bytes[0] or (bytes[1] shl 8) or (bytes[2] shl 16) or (bytes[3] shl 24);
    
    FSampleRate := sr;
    FNumChannels := nc;
    FBitsPerSample := bps;
    
    if FNumChannels > MAX_CHANNELS then
      FNumChannels := MAX_CHANNELS;
    
    sampleCount := dataSize div (FNumChannels * (bps div 8));
    FNumSamples := sampleCount;
    
    for ch := 0 to FNumChannels - 1 do
      SetLength(FSamples[ch], sampleCount);
    
    // Read samples
    for s := 0 to sampleCount - 1 do
    begin
      case bps of
        16:
          for ch := 0 to FNumChannels - 1 do
          begin
            BlockRead(f, b, 1); bytes[0] := b;
            BlockRead(f, b, 1); bytes[1] := b;
            sample16 := bytes[0] or (bytes[1] shl 8);
            if bytes[1] and $80 <> 0 then
              sample16 := sample16 or $FFFF0000;
            FSamples[ch][s] := sample16 / 32768.0;
          end;
        24:
          for ch := 0 to FNumChannels - 1 do
          begin
            for i := 0 to 2 do
            begin
              BlockRead(f, b, 1);
              bytes[i] := b;
            end;
            sample32 := bytes[0] or (bytes[1] shl 8) or (bytes[2] shl 16);
            if bytes[2] and $80 <> 0 then
              sample32 := sample32 or $FF000000;
            FSamples[ch][s] := sample32 / 8388608.0;
          end;
      end;
    end;
    
    Result := True;
  finally
    CloseFile(f);
  end;
end;

function TWAVFile.WriteWAV(filename: string): Boolean;
var
  f: file;
  bytes: array[0..3] of Byte;
  i, ch, s: Integer;
  sample16: SmallInt;
  sample32: Longint;
  value: Double;
  dataSize, chunkSize: Longint;
  b: Byte;
begin
  Result := False;
  
  AssignFile(f, filename);
  Rewrite(f, 1);
  
  try
    // RIFF header
    b := Ord('R'); BlockWrite(f, b, 1);
    b := Ord('I'); BlockWrite(f, b, 1);
    b := Ord('F'); BlockWrite(f, b, 1);
    b := Ord('F'); BlockWrite(f, b, 1);
    
    chunkSize := 36 + FNumSamples * FNumChannels * (FBitsPerSample div 8);
    bytes[0] := chunkSize and $FF;
    bytes[1] := (chunkSize shr 8) and $FF;
    bytes[2] := (chunkSize shr 16) and $FF;
    bytes[3] := (chunkSize shr 24) and $FF;
    for i := 0 to 3 do
    begin
      b := bytes[i];
      BlockWrite(f, b, 1);
    end;
    
    b := Ord('W'); BlockWrite(f, b, 1);
    b := Ord('A'); BlockWrite(f, b, 1);
    b := Ord('V'); BlockWrite(f, b, 1);
    b := Ord('E'); BlockWrite(f, b, 1);
    
    // fmt subchunk
    b := Ord('f'); BlockWrite(f, b, 1);
    b := Ord('m'); BlockWrite(f, b, 1);
    b := Ord('t'); BlockWrite(f, b, 1);
    b := Ord(' '); BlockWrite(f, b, 1);
    
    b := 16; BlockWrite(f, b, 1);
    b := 0; BlockWrite(f, b, 1);
    b := 0; BlockWrite(f, b, 1);
    b := 0; BlockWrite(f, b, 1);
    b := 1; BlockWrite(f, b, 1);
    b := 0; BlockWrite(f, b, 1);
    b := FNumChannels; BlockWrite(f, b, 1);
    b := 0; BlockWrite(f, b, 1);
    
    bytes[0] := FSampleRate and $FF;
    bytes[1] := (FSampleRate shr 8) and $FF;
    bytes[2] := (FSampleRate shr 16) and $FF;
    bytes[3] := (FSampleRate shr 24) and $FF;
    for i := 0 to 3 do
    begin
      b := bytes[i];
      BlockWrite(f, b, 1);
    end;
    
    dataSize := FNumSamples * FNumChannels * (FBitsPerSample div 8);
    bytes[0] := dataSize and $FF;
    bytes[1] := (dataSize shr 8) and $FF;
    bytes[2] := (dataSize shr 16) and $FF;
    bytes[3] := (dataSize shr 24) and $FF;
    for i := 0 to 3 do
    begin
      b := bytes[i];
      BlockWrite(f, b, 1);
    end;
    
    b := (FNumChannels * (FBitsPerSample div 8)) and $FF;
    BlockWrite(f, b, 1);
    b := ((FNumChannels * (FBitsPerSample div 8)) shr 8) and $FF;
    BlockWrite(f, b, 1);
    b := FBitsPerSample and $FF;
    BlockWrite(f, b, 1);
    b := (FBitsPerSample shr 8) and $FF;
    BlockWrite(f, b, 1);
    
    // data subchunk
    b := Ord('d'); BlockWrite(f, b, 1);
    b := Ord('a'); BlockWrite(f, b, 1);
    b := Ord('t'); BlockWrite(f, b, 1);
    b := Ord('a'); BlockWrite(f, b, 1);
    
    bytes[0] := dataSize and $FF;
    bytes[1] := (dataSize shr 8) and $FF;
    bytes[2] := (dataSize shr 16) and $FF;
    bytes[3] := (dataSize shr 24) and $FF;
    for i := 0 to 3 do
    begin
      b := bytes[i];
      BlockWrite(f, b, 1);
    end;
    
    // Write samples
    for s := 0 to FNumSamples - 1 do
    begin
      if FBitsPerSample = 16 then
      begin
        for ch := 0 to FNumChannels - 1 do
        begin
          value := Max(-1.0, Min(1.0, FSamples[ch][s]));
          sample16 := Round(value * 32767);
          b := sample16 and $FF; BlockWrite(f, b, 1);
          b := (sample16 shr 8) and $FF; BlockWrite(f, b, 1);
        end;
      end
      else if FBitsPerSample = 24 then
      begin
        for ch := 0 to FNumChannels - 1 do
        begin
          value := Max(-1.0, Min(1.0, FSamples[ch][s]));
          sample32 := Round(value * 8388607);
          b := sample32 and $FF; BlockWrite(f, b, 1);
          b := (sample32 shr 8) and $FF; BlockWrite(f, b, 1);
          b := (sample32 shr 16) and $FF; BlockWrite(f, b, 1);
        end;
      end;
    end;
    
    Result := True;
  finally
    CloseFile(f);
  end;
end;

// TMeterRecorder Implementation
constructor TMeterRecorder.Create;
begin
  FMetricCount := 0;
  FGainReductionCount := 0;
  SetLength(FMetrics, 1000);
  SetLength(FGainReductionSamples, 100000);
end;

destructor TMeterRecorder.Destroy;
begin
  SetLength(FMetrics, 0);
  SetLength(FGainReductionSamples, 0);
  inherited;
end;

procedure TMeterRecorder.RecordMetrics(metrics: TBlockMetrics);
begin
  if FMetricCount >= Length(FMetrics) then
    SetLength(FMetrics, FMetricCount + 1000);
  FMetrics[FMetricCount] := metrics;
  Inc(FMetricCount);
end;

procedure TMeterRecorder.RecordGainReduction(gainDB: Double);
begin
  if FGainReductionCount >= Length(FGainReductionSamples) then
    SetLength(FGainReductionSamples, FGainReductionCount + 100000);
  FGainReductionSamples[FGainReductionCount] := gainDB;
  Inc(FGainReductionCount);
end;

procedure TMeterRecorder.ExportCSV(filename: string);
var
  f: TextFile;
  i: Integer;
begin
  AssignFile(f, filename);
  Rewrite(f);
  
  try
    WriteLn(f, 'Sample,GainReductionDB');
    for i := 0 to FGainReductionCount - 1 do
      WriteLn(f, i, ',', FGainReductionSamples[i]:0:6);
  finally
    CloseFile(f);
  end;
end;

procedure TMeterRecorder.PrintSummary;
var
  i: Integer;
  avgInputPeak, avgInputRMS, avgOutputPeak, avgOutputRMS, avgGR: Double;
begin
  if FMetricCount = 0 then
    Exit;
  
  avgInputPeak := 0;
  avgInputRMS := 0;
  avgOutputPeak := 0;
  avgOutputRMS := 0;
  avgGR := 0;
  
  for i := 0 to FMetricCount - 1 do
  begin
    if FMetrics[i].InputPeak > 0 then
      avgInputPeak := avgInputPeak + TDSPMath.LinearToDB(FMetrics[i].InputPeak);
    if FMetrics[i].InputRMS > 0 then
      avgInputRMS := avgInputRMS + TDSPMath.LinearToDB(FMetrics[i].InputRMS);
    if FMetrics[i].OutputPeak > 0 then
      avgOutputPeak := avgOutputPeak + TDSPMath.LinearToDB(FMetrics[i].OutputPeak);
    if FMetrics[i].OutputRMS > 0 then
      avgOutputRMS := avgOutputRMS + TDSPMath.LinearToDB(FMetrics[i].OutputRMS);
    avgGR := avgGR + FMetrics[i].AvgGainReductionDB;
  end;
  
  avgInputPeak := avgInputPeak / FMetricCount;
  avgInputRMS := avgInputRMS / FMetricCount;
  avgOutputPeak := avgOutputPeak / FMetricCount;
  avgOutputRMS := avgOutputRMS / FMetricCount;
  avgGR := avgGR / FMetricCount;
  
  WriteLn('');
  WriteLn('=== COMPRESSOR METERING SUMMARY ===');
  WriteLn('Input Peak (dB):       ', avgInputPeak:0:2);
  WriteLn('Input RMS (dB):        ', avgInputRMS:0:2);
  WriteLn('Output Peak (dB):      ', avgOutputPeak:0:2);
  WriteLn('Output RMS (dB):       ', avgOutputRMS:0:2);
  WriteLn('Avg Gain Reduction:    ', avgGR:0:2, ' dB');
  WriteLn('');
end;

// ============================================================================
// CLI / Main
// ============================================================================

procedure PrintUsage;
begin
  WriteLn('AudioCompressor - High-Quality DSP Compressor');
  WriteLn('');
  WriteLn('Usage: AudioCompressor [options] input.wav output.wav');
  WriteLn('');
  WriteLn('Compression Controls:');
  WriteLn('  -t <dB>        Threshold (-60 to 0, default: -20)');
  WriteLn('  -r <ratio>     Compression ratio (1.0 to 100.0, default: 4.0)');
  WriteLn('  -a <ms>        Attack time (0.1 to 300ms, default: 10ms)');
  WriteLn('  -rl <ms>       Release time (1 to 2000ms, default: 100ms)');
  WriteLn('  -k <dB>        Knee width (0 to 30dB, default: 0)');
  WriteLn('  -m <dB>        Makeup gain (-20 to 20dB, default: 0)');
  WriteLn('');
  WriteLn('Mode & Sidechain:');
  WriteLn('  -link <mode>   Stereo linking (independent, average, max, rms, midside)');
  WriteLn('  -env <mode>    Envelope mode (peak, rms, truerms, adaptive)');
  WriteLn('  -rel <curve>   Release curve (linear, exponential, adaptive)');
  WriteLn('');
  WriteLn('Processing:');
  WriteLn('  -la <ms>       Lookahead (0 to 10ms, default: 0)');
  WriteLn('  -mix <0-1>     Mix dry/wet (1.0=dry, 0.0=wet, default: 0.0)');
  WriteLn('  -bypass        Disable compression');
  WriteLn('');
  WriteLn('Output:');
  WriteLn('  -csv <file>    Export gain reduction curve to CSV');
  WriteLn('  -v             Verbose output');
  WriteLn('');
end;

procedure PrintSettings(params: TCompressorParams);
begin
  WriteLn('=== COMPRESSOR SETTINGS ===');
  WriteLn('Threshold:    ', params.Threshold:0:1, ' dB');
  WriteLn('Ratio:        ', params.Ratio:0:2, ':1');
  WriteLn('Attack:       ', params.AttackMS:0:1, ' ms');
  WriteLn('Release:      ', params.ReleaseMS:0:1, ' ms');
  WriteLn('Knee:         ', params.KneeDB:0:1, ' dB');
  WriteLn('Makeup Gain:  ', params.MakeupGain:0:1, ' dB');
  WriteLn('Lookahead:    ', params.LookaheadMS:0:1, ' ms');
  WriteLn('Mix:          ', params.MixDry:0:2, ' (0=wet, 1=dry)');
  WriteLn('');
end;

var
  inputFile, outputFile, csvFile: string;
  params: TCompressorParams;
  wavIn, wavOut: TWAVFile;
  compressor: TCompressorCore;
  meter: TMeterRecorder;
  input, output: TPCMSamples;
  blockSize, totalSamples, processed, toProcess: Integer;
  metrics: TBlockMetrics;
  s, ch, i: Integer;
  verbose: Boolean;
  currentArg: string;

begin
  params.Threshold := -20;
  params.Ratio := 4.0;
  params.AttackMS := 10;
  params.ReleaseMS := 100;
  params.KneeDB := 0;
  params.MakeupGain := 0;
  params.StereoLinkMode := slmMax;
  params.EnvelopeMode := emPeak;
  params.ReleaseCurve := rcLinear;
  params.LookaheadMS := 0;
  params.MixDry := 0.0;
  params.Bypass := False;
  
  inputFile := '';
  outputFile := '';
  csvFile := '';
  verbose := False;
  
  if ParamCount < 2 then
  begin
    PrintUsage;
    Halt(1);
  end;
  
  i := 1;
  while i <= ParamCount do
  begin
    currentArg := ParamStr(i);
    
    if currentArg = '-t' then
    begin
      Inc(i);
      params.Threshold := StrToFloat(ParamStr(i));
    end
    else if currentArg = '-r' then
    begin
      Inc(i);
      params.Ratio := StrToFloat(ParamStr(i));
    end
    else if currentArg = '-a' then
    begin
      Inc(i);
      params.AttackMS := StrToFloat(ParamStr(i));
    end
    else if currentArg = '-rl' then
    begin
      Inc(i);
      params.ReleaseMS := StrToFloat(ParamStr(i));
    end
    else if currentArg = '-k' then
    begin
      Inc(i);
      params.KneeDB := StrToFloat(ParamStr(i));
    end
    else if currentArg = '-m' then
    begin
      Inc(i);
      params.MakeupGain := StrToFloat(ParamStr(i));
    end
    else if currentArg = '-la' then
    begin
      Inc(i);
      params.LookaheadMS := StrToFloat(ParamStr(i));
    end
    else if currentArg = '-mix' then
    begin
      Inc(i);
      params.MixDry := StrToFloat(ParamStr(i));
    end
    else if currentArg = '-bypass' then
      params.Bypass := True
    else if currentArg = '-csv' then
    begin
      Inc(i);
      csvFile := ParamStr(i);
    end
    else if currentArg = '-link' then
    begin
      Inc(i);
      if ParamStr(i) = 'average' then
        params.StereoLinkMode := slmAverage
      else if ParamStr(i) = 'max' then
        params.StereoLinkMode := slmMax
      else if ParamStr(i) = 'rms' then
        params.StereoLinkMode := slmRMS
      else if ParamStr(i) = 'midside' then
        params.StereoLinkMode := slmMidSide
      else
        params.StereoLinkMode := slmIndependent;
    end
    else if currentArg = '-env' then
    begin
      Inc(i);
      if ParamStr(i) = 'rms' then
        params.EnvelopeMode := emRMS
      else if ParamStr(i) = 'truerms' then
        params.EnvelopeMode := emTrueRMS
      else if ParamStr(i) = 'adaptive' then
        params.EnvelopeMode := emAdaptive
      else
        params.EnvelopeMode := emPeak;
    end
    else if currentArg = '-rel' then
    begin
      Inc(i);
      if ParamStr(i) = 'exponential' then
        params.ReleaseCurve := rcExponential
      else if ParamStr(i) = 'adaptive' then
        params.ReleaseCurve := rcAdaptive
      else
        params.ReleaseCurve := rcLinear;
    end
    else if currentArg = '-v' then
      verbose := True
    else if (Length(currentArg) > 0) and (currentArg[1] <> '-') then
    begin
      if inputFile = '' then
        inputFile := currentArg
      else if outputFile = '' then
        outputFile := currentArg;
    end;
    
    Inc(i);
  end;
  
  if (inputFile = '') or (outputFile = '') then
  begin
    WriteLn('Error: Input and output files required');
    PrintUsage;
    Halt(1);
  end;
  
  if verbose then
    PrintSettings(params);
  
  wavIn := TWAVFile.Create;
  try
    if not wavIn.ReadWAV(inputFile) then
    begin
      WriteLn('Error: Cannot read ', inputFile);
      Halt(1);
    end;
    
    if verbose then
    begin
      WriteLn('Input: ', inputFile);
      WriteLn('  Sample Rate: ', wavIn.SampleRate, ' Hz');
      WriteLn('  Channels: ', wavIn.NumChannels);
      WriteLn('  Bits: ', wavIn.BitsPerSample);
      WriteLn('  Samples: ', wavIn.NumSamples);
      WriteLn('  Duration: ', wavIn.NumSamples / wavIn.SampleRate:0:2, ' sec');
      WriteLn('');
    end;
    
    compressor := TCompressorCore.Create(wavIn.SampleRate, wavIn.NumChannels, params);
    meter := TMeterRecorder.Create;
    
    try
      SetLength(output, wavIn.NumChannels);
      for ch := 0 to wavIn.NumChannels - 1 do
        SetLength(output[ch], wavIn.NumSamples);
      
      blockSize := MAX_SAMPLES_PER_BLOCK;
      totalSamples := wavIn.NumSamples;
      processed := 0;
      
      while processed < totalSamples do
      begin
        toProcess := Min(blockSize, totalSamples - processed);
        
        SetLength(input, wavIn.NumChannels);
        for ch := 0 to wavIn.NumChannels - 1 do
        begin
          SetLength(input[ch], toProcess);
          for s := 0 to toProcess - 1 do
            input[ch][s] := wavIn.Samples[ch][processed + s];
        end;
        
        compressor.ProcessBlock(input, output, toProcess, metrics);
        meter.RecordMetrics(metrics);
        
        for ch := 0 to wavIn.NumChannels - 1 do
        begin
          for s := 0 to toProcess - 1 do
            wavIn.Samples[ch][processed + s] := output[ch][s];
        end;
        
        if verbose then
          WriteLn('Processed: ', ((processed + toProcess) * 100 div totalSamples), '%');
        
        processed := processed + toProcess;
        
        for ch := 0 to wavIn.NumChannels - 1 do
          SetLength(input[ch], 0);
        SetLength(input, 0);
      end;
      
      meter.PrintSummary;
      
      wavOut := TWAVFile.Create;
      try
        wavOut.FSampleRate := wavIn.FSampleRate;
        wavOut.FNumChannels := wavIn.FNumChannels;
        wavOut.FBitsPerSample := wavIn.FBitsPerSample;
        wavOut.FNumSamples := wavIn.FNumSamples;
        wavOut.FSamples := wavIn.FSamples;
        
        if wavOut.WriteWAV(outputFile) then
        begin
          if verbose then
            WriteLn('Output written: ', outputFile);
        end
        else
        begin
          WriteLn('Error: Cannot write ', outputFile);
          Halt(1);
        end;
      finally
        wavOut.Free;
      end;
      
      if csvFile <> '' then
      begin
        meter.ExportCSV(csvFile);
        if verbose then
          WriteLn('CSV exported: ', csvFile);
      end;
      
    finally
      compressor.Free;
      meter.Free;
      for ch := 0 to Length(output) - 1 do
        SetLength(output[ch], 0);
      SetLength(output, 0);
    end;
    
  finally
    wavIn.Free;
  end;
  
  WriteLn('Done');
end.
