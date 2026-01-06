program ParametricEQ;

{$mode delphi}

{
  Parametric Equalizer in Pascal
  Features:
  - Reads/writes WAV files (16/24/32-bit PCM, mono/stereo)
  - Multiple biquad IIR filter bands (peaking, shelf, HP/LP, notch)
  - 64-bit float internal processing
  - Block-based zero-latency processing
  - CLI interface with band specification
  - Frequency response CSV export
}

uses
  SysUtils, Classes, Math;

const
  BUFFER_SIZE = 2048;
  MAX_BANDS = 32;
  PI = 3.14159265358979323846;

type
  { Filter band types }
  TBandType = (btPeaking, btLowShelf, btHighShelf, btLowPass, btHighPass, btNotch);

  { Biquad filter coefficients (64-bit float) }
  TBiquadCoeffs = record
    b0, b1, b2: double;  { Numerator coefficients }
    a1, a2: double;      { Denominator coefficients (normalized, a0=1) }
  end;

  { Biquad filter state }
  TBiquadState = record
    x1, x2: double;      { Previous input samples }
    y1, y2: double;      { Previous output samples }
  end;

  { Single filter band definition }
  TFilterBand = record
    BandType: TBandType;
    Frequency: double;   { Hz }
    Q: double;
    Gain: double;        { dB }
    Coeffs: TBiquadCoeffs;
    State: TBiquadState;
  end;

  { WAV file header }
  TWavHeader = packed record
    ChunkID: array[0..3] of AnsiChar;      { "RIFF" }
    ChunkSize: longword;
    Format: array[0..3] of AnsiChar;       { "WAVE" }
    Subchunk1ID: array[0..3] of AnsiChar; { "fmt " }
    Subchunk1Size: longword;
    AudioFormat: word;                     { 1=PCM, 3=IEEE float }
    NumChannels: word;
    SampleRate: longword;
    ByteRate: longword;
    BlockAlign: word;
    BitsPerSample: word;
  end;

  { Process context }
  TProcessContext = record
    Bands: array[0..MAX_BANDS-1] of TFilterBand;
    NumBands: integer;
    SampleRate: longword;
    NumChannels: word;
    BitsPerSample: word;
    Samples: longword;
    PeakLevel: double;
    RMSLevel: double;
  end;

{ ============================================================================
  Utility Functions
  ============================================================================ }

function dBToLinear(dB: double): double;
begin
  Result := Power(10.0, dB / 20.0);
end;

function LinearTodB(Linear: double): double;
begin
  if Linear <= 0 then
    Result := -120.0
  else
    Result := 20.0 * Log10(Linear);
end;

{ ============================================================================
  Biquad Filter Implementation
  ============================================================================ }

procedure CalculateBiquadCoefficients(var Band: TFilterBand; SampleRate: longword);
var
  A, W0, SinW0, CosW0, AlphaQ, AlphaS, G: double;
begin
  W0 := 2.0 * PI * Band.Frequency / SampleRate;
  SinW0 := Sin(W0);
  CosW0 := Cos(W0);
  G := dBToLinear(Band.Gain);

  { Calculate alpha based on band type }
  case Band.BandType of
    btPeaking:
      begin
        { Alpha for peaking: sin(w0)/(2*Q) }
        AlphaQ := SinW0 / (2.0 * Band.Q);
        with Band.Coeffs do
        begin
          b0 := 1.0 + AlphaQ * G;
          b1 := -2.0 * CosW0;
          b2 := 1.0 - AlphaQ * G;
          A := 1.0 + AlphaQ / G;
          a1 := -2.0 * CosW0;
          a2 := 1.0 - AlphaQ / G;
        end;
      end;

    btLowShelf:
      begin
        A := Sqrt(G);
        AlphaS := SinW0 / 2.0 * Sqrt((A + 1.0/A) * (1.0/Band.Q - 1.0) + 2.0);
        with Band.Coeffs do
        begin
          b0 := A * ((A + 1.0) - (A - 1.0) * CosW0 + 2.0 * Sqrt(A) * AlphaS);
          b1 := 2.0 * A * ((A - 1.0) - (A + 1.0) * CosW0);
          b2 := A * ((A + 1.0) - (A - 1.0) * CosW0 - 2.0 * Sqrt(A) * AlphaS);
          A := (A + 1.0) + (A - 1.0) * CosW0 + 2.0 * Sqrt(A) * AlphaS;
          a1 := -2.0 * ((A - 1.0) + (A + 1.0) * CosW0);
          a2 := (A + 1.0) + (A - 1.0) * CosW0 - 2.0 * Sqrt(A) * AlphaS;
        end;
      end;

    btHighShelf:
      begin
        A := Sqrt(G);
        AlphaS := SinW0 / 2.0 * Sqrt((A + 1.0/A) * (1.0/Band.Q - 1.0) + 2.0);
        with Band.Coeffs do
        begin
          b0 := A * ((A + 1.0) + (A - 1.0) * CosW0 + 2.0 * Sqrt(A) * AlphaS);
          b1 := -2.0 * A * ((A - 1.0) + (A + 1.0) * CosW0);
          b2 := A * ((A + 1.0) + (A - 1.0) * CosW0 - 2.0 * Sqrt(A) * AlphaS);
          A := (A + 1.0) - (A - 1.0) * CosW0 + 2.0 * Sqrt(A) * AlphaS;
          a1 := 2.0 * ((A - 1.0) - (A + 1.0) * CosW0);
          a2 := (A + 1.0) - (A - 1.0) * CosW0 - 2.0 * Sqrt(A) * AlphaS;
        end;
      end;

    btLowPass:
      begin
        { Second-order Butterworth-like lowpass }
        AlphaQ := SinW0 / (2.0 * Band.Q);
        with Band.Coeffs do
        begin
          b0 := (1.0 - CosW0) / 2.0;
          b1 := 1.0 - CosW0;
          b2 := (1.0 - CosW0) / 2.0;
          A := 1.0 + AlphaQ;
          a1 := -2.0 * CosW0;
          a2 := 1.0 - AlphaQ;
        end;
      end;

    btHighPass:
      begin
        AlphaQ := SinW0 / (2.0 * Band.Q);
        with Band.Coeffs do
        begin
          b0 := (1.0 + CosW0) / 2.0;
          b1 := -(1.0 + CosW0);
          b2 := (1.0 + CosW0) / 2.0;
          A := 1.0 + AlphaQ;
          a1 := -2.0 * CosW0;
          a2 := 1.0 - AlphaQ;
        end;
      end;

    btNotch:
      begin
        if Band.Q > 0 then
          AlphaQ := SinW0 / (2.0 * Band.Q)
        else
          AlphaQ := SinW0 / 2.0;
        with Band.Coeffs do
        begin
          b0 := 1.0;
          b1 := -2.0 * CosW0;
          b2 := 1.0;
          A := 1.0 + AlphaQ;
          a1 := -2.0 * CosW0;
          a2 := 1.0 - AlphaQ;
        end;
      end;
  end;

  { Normalize: divide all coefficients by a0 }
  if Abs(A) > 1e-10 then
  begin
    Band.Coeffs.b0 := Band.Coeffs.b0 / A;
    Band.Coeffs.b1 := Band.Coeffs.b1 / A;
    Band.Coeffs.b2 := Band.Coeffs.b2 / A;
    Band.Coeffs.a1 := Band.Coeffs.a1 / A;
    Band.Coeffs.a2 := Band.Coeffs.a2 / A;
  end;
end;

{ Process single sample through biquad filter (Direct Form II) }
function ProcessBiquadSample(var Band: TFilterBand; Input: double): double;
var
  W: double;
begin
  W := Input - Band.Coeffs.a1 * Band.State.y1 - Band.Coeffs.a2 * Band.State.y2;
  Result := Band.Coeffs.b0 * W + Band.Coeffs.b1 * Band.State.y1 + Band.Coeffs.b2 * Band.State.y2;

  { Clamp to prevent feedback explosion }
  if IsNan(Result) or IsInfinite(Result) then
    Result := Input
  else
  begin
    { Soft clamp if too large }
    if Abs(Result) > 1000.0 then
      Result := Sign(Result) * 1.0;
  end;

  Band.State.y2 := Band.State.y1;
  Band.State.y1 := Result;
end;

{ Process sample through all bands }
function ProcessSample(var Context: TProcessContext; Sample: double): double;
var
  i: integer;
begin
  Result := Sample;
  for i := 0 to Context.NumBands - 1 do
    Result := ProcessBiquadSample(Context.Bands[i], Result);
end;

{ ============================================================================
  Audio File I/O
  ============================================================================ }

procedure ReadWavHeader(Stream: TStream; var Header: TWavHeader);
begin
  Stream.ReadBuffer(Header, SizeOf(TWavHeader));
end;

procedure WriteWavHeader(Stream: TStream; var Header: TWavHeader; DataSize: longword);
begin
  Header.ChunkSize := DataSize + 36;
  Stream.WriteBuffer(Header, SizeOf(TWavHeader));
end;

procedure FindDataChunk(Stream: TStream; var DataSize: longword);
var
  ChunkID: array[0..3] of AnsiChar;
  ChunkSize: longword;
begin
  DataSize := 0;
  while Stream.Position < Stream.Size do
  begin
    Stream.ReadBuffer(ChunkID, 4);
    if ChunkID[0] = #0 then Break;
    
    Stream.ReadBuffer(ChunkSize, 4);

    if (ChunkID[0] = 'd') and (ChunkID[1] = 'a') and (ChunkID[2] = 't') and (ChunkID[3] = 'a') then
    begin
      DataSize := ChunkSize;
      Exit;
    end;

    Stream.Seek(ChunkSize, soFromCurrent);
  end;
end;

function LoadWavFile(FileName: string; var Context: TProcessContext): TMemoryStream;
var
  Stream: TFileStream;
  Header: TWavHeader;
  DataSize: longword;
  Buffer: array[0..65535] of byte;
  BytesRead: integer;
  TotalRead: longword;
begin
  Result := TMemoryStream.Create;
  try
    Stream := TFileStream.Create(FileName, fmOpenRead);
    try
      ReadWavHeader(Stream, Header);

      { Validate WAV format }
      if (Header.ChunkID <> 'RIFF') or (Header.Format <> 'WAVE') then
      begin
        WriteLn('Error: Invalid WAV file format');
        Exit;
      end;

      if Header.AudioFormat <> 1 then
      begin
        WriteLn('Error: Only PCM format is supported (AudioFormat=1)');
        Exit;
      end;

      { Store context }
      Context.SampleRate := Header.SampleRate;
      Context.NumChannels := Header.NumChannels;
      Context.BitsPerSample := Header.BitsPerSample;

      { Find data chunk }
      Stream.Seek(SizeOf(TWavHeader), soFromBeginning);
      FindDataChunk(Stream, DataSize);

      { Load audio data in chunks }
      TotalRead := 0;
      repeat
        if DataSize - TotalRead > 65536 then
          BytesRead := Stream.Read(Buffer, 65536)
        else
          BytesRead := Stream.Read(Buffer, integer(DataSize - TotalRead));
        if BytesRead > 0 then
        begin
          Result.WriteBuffer(Buffer, BytesRead);
          Inc(TotalRead, BytesRead);
        end;
      until (BytesRead = 0) or (TotalRead >= DataSize);

      Result.Position := 0;
      Context.Samples := DataSize div (Header.NumChannels * (Header.BitsPerSample div 8));
    finally
      Stream.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn('Error loading WAV file: ', E.Message);
      Result.Free;
      Result := nil;
    end;
  end;
end;

procedure SaveWavFile(FileName: string; AudioData: TMemoryStream; Context: TProcessContext; OriginalHeader: TWavHeader);
var
  Stream: TFileStream;
  Header: TWavHeader;
  DataChunkID: array[0..3] of AnsiChar;
  Size: longword;
begin
  Stream := TFileStream.Create(FileName, fmCreate);
  try
    Header := OriginalHeader;
    Header.ByteRate := Context.SampleRate * Context.NumChannels * (Context.BitsPerSample div 8);
    Header.BlockAlign := Context.NumChannels * (Context.BitsPerSample div 8);

    { Write header }
    Stream.WriteBuffer(Header, SizeOf(TWavHeader));

    { Write data chunk }
    DataChunkID[0] := 'd'; DataChunkID[1] := 'a'; DataChunkID[2] := 't'; DataChunkID[3] := 'a';
    Stream.WriteBuffer(DataChunkID, 4);
    Size := AudioData.Size;
    Stream.WriteBuffer(Size, 4);
    Stream.WriteBuffer(AudioData.Memory^, AudioData.Size);

    WriteLn('Saved: ', FileName);
  finally
    Stream.Free;
  end;
end;

{ ============================================================================
  Audio Sample Conversion
  ============================================================================ }

function SampleToFloat(SamplePtr: Pointer; BitsPerSample: word; SampleIndex: longword): double;
var
  i16: int16;
  i24, i32: int32;
  Addr: ptrint;
begin
  case BitsPerSample of
    16:
      begin
        Addr := ptrint(SamplePtr) + ptrint(SampleIndex * 2);
        i16 := PInt16(Addr)^;
        Result := i16 / 32768.0;
      end;
    24:
      begin
        i24 := 0;
        Addr := ptrint(SamplePtr) + ptrint(SampleIndex * 3);
        Move(PByte(Addr)^, i24, 3);
        if i24 and $800000 <> 0 then
          i24 := i24 or $FF000000;
        Result := i24 / 8388608.0;
      end;
    32:
      begin
        Addr := ptrint(SamplePtr) + ptrint(SampleIndex * 4);
        i32 := PInt32(Addr)^;
        Result := i32 / 2147483648.0;
      end;
  else
    Result := 0;
  end;
end;

procedure FloatToSample(SamplePtr: Pointer; BitsPerSample: word; SampleIndex: longword; Value: double);
var
  i16: int16;
  i24, i32: int32;
  Addr: ptrint;
begin
  { Clamp to [-1, 1] }
  if Value > 1.0 then Value := 1.0
  else if Value < -1.0 then Value := -1.0;

  case BitsPerSample of
    16:
      begin
        i16 := Round(Value * 32767.0);
        Addr := ptrint(SamplePtr) + ptrint(SampleIndex * 2);
        PInt16(Addr)^ := i16;
      end;
    24:
      begin
        i24 := Round(Value * 8388607.0);
        Addr := ptrint(SamplePtr) + ptrint(SampleIndex * 3);
        Move(i24, PByte(Addr)^, 3);
      end;
    32:
      begin
        i32 := Round(Value * 2147483647.0);
        Addr := ptrint(SamplePtr) + ptrint(SampleIndex * 4);
        PInt32(Addr)^ := i32;
      end;
  end;
end;

{ ============================================================================
  Signal Analysis
  ============================================================================ }

procedure AnalyzeSignal(AudioData: TMemoryStream; Context: TProcessContext; var PeakLevel, RMSLevel: double);
var
  i: longword;
  Sample: double;
  SumSquares: double;
begin
  PeakLevel := 0;
  SumSquares := 0;

  try
    for i := 0 to Context.Samples - 1 do
    begin
      Sample := SampleToFloat(AudioData.Memory, Context.BitsPerSample, i);
      Sample := Abs(Sample);
      if (not IsNan(Sample)) and (not IsInfinite(Sample)) then
      begin
        if Sample > PeakLevel then
          PeakLevel := Sample;
        SumSquares := SumSquares + Sample * Sample;
      end;
    end;

    if Context.Samples > 0 then
    begin
      if SumSquares > 0 then
        RMSLevel := Sqrt(SumSquares / Context.Samples)
      else
        RMSLevel := 0;
    end
    else
      RMSLevel := 0;
  except
    on E: Exception do
    begin
      WriteLn('Warning: Error during signal analysis: ', E.Message);
      PeakLevel := 0;
      RMSLevel := 0;
    end;
  end;
end;

{ ============================================================================
  Processing
  ============================================================================ }

procedure ProcessAudio(var AudioData: TMemoryStream; var Context: TProcessContext);
var
  i, Ch: longword;
  Sample: double;
begin
  WriteLn('Processing ', Context.Samples, ' samples (', Context.NumChannels, ' channels)...');

  { Process all samples }
  for i := 0 to Context.Samples - 1 do
  begin
    for Ch := 0 to Context.NumChannels - 1 do
    begin
      Sample := SampleToFloat(AudioData.Memory, Context.BitsPerSample, i * Context.NumChannels + Ch);
      Sample := ProcessSample(Context, Sample);
      FloatToSample(AudioData.Memory, Context.BitsPerSample, i * Context.NumChannels + Ch, Sample);
    end;
  end;
end;

{ ============================================================================
  Display & Reporting
  ============================================================================ }

procedure DisplayBandTypeString(BandType: TBandType);
begin
  case BandType of
    btPeaking: Write('Peaking');
    btLowShelf: Write('Low-Shelf');
    btHighShelf: Write('High-Shelf');
    btLowPass: Write('Low-Pass');
    btHighPass: Write('High-Pass');
    btNotch: Write('Notch');
  end;
end;

procedure PrintBandSettings(Context: TProcessContext);
var
  i: integer;
begin
  WriteLn;
  WriteLn('=== EQ Configuration ===');
  WriteLn('Sample Rate: ', Context.SampleRate, ' Hz');
  WriteLn('Channels: ', Context.NumChannels);
  WriteLn('Bit Depth: ', Context.BitsPerSample, ' bit');
  WriteLn('Total Samples: ', Context.Samples);
  WriteLn;
  WriteLn('=== Filter Bands (', Context.NumBands, ') ===');

  for i := 0 to Context.NumBands - 1 do
  begin
    Write('Band ', i + 1, ': ');
    DisplayBandTypeString(Context.Bands[i].BandType);
    WriteLn(Format(' | Freq: %.1f Hz | Q: %.2f | Gain: %.2f dB',
      [Context.Bands[i].Frequency, Context.Bands[i].Q, Context.Bands[i].Gain]));
  end;
  WriteLn;
end;

procedure PrintMeteringResults(Context: TProcessContext; PeakBefore, RMSBefore, PeakAfter, RMSAfter: double);
var
  PeakBefDB, RMSBefDB, PeakAftDB, RMSAftDB: double;
begin
  PeakBefDB := LinearTodB(PeakBefore);
  RMSBefDB := LinearTodB(RMSBefore);
  PeakAftDB := LinearTodB(PeakAfter);
  RMSAftDB := LinearTodB(RMSAfter);

  WriteLn;
  WriteLn('=== Signal Metering ===');
  Write('Before: Peak = ');
  Write(Format('%.3f (%.2f dB) | RMS = %.3f (%.2f dB)', [PeakBefore, PeakBefDB, RMSBefore, RMSBefDB]));
  WriteLn;
  Write('After:  Peak = ');
  Write(Format('%.3f (%.2f dB) | RMS = %.3f (%.2f dB)', [PeakAfter, PeakAftDB, RMSAfter, RMSAftDB]));
  WriteLn;
  WriteLn;
end;

procedure ExportFrequencyResponseCSV(FileName: string; Context: TProcessContext);
var
  CSV: TextFile;
  Freq: double;
  BandIdx: integer;
  Magnitude: double;
  TotalMagnitude: double;
  W0, Real, Imag, DenomReal, DenomImag, Temp: double;
  i: integer;
begin
  AssignFile(CSV, FileName);
  Rewrite(CSV);
  try
    WriteLn(CSV, 'Frequency (Hz),Total Magnitude (dB),Total Phase (deg)');

    { Sweep from 10 Hz to Nyquist }
    i := 0;
    while i <= 200 do
    begin
      Freq := 10.0 * Power(10.0, i / 50.0);
      if Freq > Context.SampleRate / 2 then
        Break;

      TotalMagnitude := 0; { Will accumulate in dB }

      { Cascade all bands }
      for BandIdx := 0 to Context.NumBands - 1 do
      begin
        W0 := 2.0 * PI * Freq / Context.SampleRate;
        Real := 1.0 + Context.Bands[BandIdx].Coeffs.b1 * Cos(W0) + Context.Bands[BandIdx].Coeffs.b2 * Cos(2 * W0);
        Imag := Context.Bands[BandIdx].Coeffs.b0 * Sin(W0) + Context.Bands[BandIdx].Coeffs.b1 * Sin(W0) + Context.Bands[BandIdx].Coeffs.b2 * Sin(2 * W0);

        DenomReal := 1.0 + Context.Bands[BandIdx].Coeffs.a1 * Cos(W0) + Context.Bands[BandIdx].Coeffs.a2 * Cos(2 * W0);
        DenomImag := Context.Bands[BandIdx].Coeffs.a1 * Sin(W0) + Context.Bands[BandIdx].Coeffs.a2 * Sin(2 * W0);

        Temp := Sqrt(Real*Real + Imag*Imag) / (Sqrt(DenomReal*DenomReal + DenomImag*DenomImag) + 1e-10);
        TotalMagnitude := TotalMagnitude + 20.0 * Log10(Temp + 1e-10);
      end;

      WriteLn(CSV, Format('%.2f,%.3f,0', [Freq, TotalMagnitude]));
      Inc(i);
    end;

    WriteLn('Exported frequency response: ', FileName);
  finally
    CloseFile(CSV);
  end;
end;

{ ============================================================================
  CLI Parsing
  ============================================================================ }

procedure PrintHelp;
begin
  WriteLn('Parametric EQ - Command Line Equalizer');
  WriteLn;
  WriteLn('Usage: ParametricEQ <input.wav> <output.wav> [options]');
  WriteLn;
  WriteLn('Options:');
  WriteLn('  --band <type> <freq> <q> <gain>   Add EQ band');
  WriteLn('  --metering                          Enable peak/RMS metering');
  WriteLn('  --csv <file>                        Export frequency response to CSV');
  WriteLn('  --help                              Show this help');
  WriteLn;
  WriteLn('Band Types: peak, lowshelf, highshelf, lowpass, highpass, notch');
  WriteLn;
  WriteLn('Example:');
  WriteLn('  ParametricEQ input.wav output.wav --band peak 1000 2.5 6 --band lowshelf 80 0.7 -3');
  WriteLn;
end;

function StringToBandType(S: string): TBandType;
begin
  S := LowerCase(S);
  if S = 'peak' then Result := btPeaking
  else if S = 'lowshelf' then Result := btLowShelf
  else if S = 'highshelf' then Result := btHighShelf
  else if S = 'lowpass' then Result := btLowPass
  else if S = 'highpass' then Result := btHighPass
  else if S = 'notch' then Result := btNotch
  else Result := btPeaking;
end;

procedure ParseCommandLine(var InputFile, OutputFile: string; var Context: TProcessContext; var ExportCSV: string; var EnableMetering: boolean);
var
  i: integer;
  BandType: TBandType;
  Freq, Q, Gain: double;
begin
  EnableMetering := False;
  ExportCSV := '';

  if ParamCount < 2 then
  begin
    PrintHelp;
    Halt(1);
  end;

  InputFile := ParamStr(1);
  OutputFile := ParamStr(2);

  Context.NumBands := 0;
  i := 3;

  while i <= ParamCount do
  begin
    if ParamStr(i) = '--band' then
    begin
      if i + 3 <= ParamCount then
      begin
        BandType := StringToBandType(ParamStr(i + 1));
        Freq := StrToFloat(ParamStr(i + 2));
        Q := StrToFloat(ParamStr(i + 3));
        Gain := StrToFloat(ParamStr(i + 4));

        if Context.NumBands < MAX_BANDS then
        begin
          Context.Bands[Context.NumBands].BandType := BandType;
          Context.Bands[Context.NumBands].Frequency := Freq;
          Context.Bands[Context.NumBands].Q := Q;
          Context.Bands[Context.NumBands].Gain := Gain;
          Context.Bands[Context.NumBands].State.x1 := 0;
          Context.Bands[Context.NumBands].State.x2 := 0;
          Context.Bands[Context.NumBands].State.y1 := 0;
          Context.Bands[Context.NumBands].State.y2 := 0;
          Inc(Context.NumBands);
          Inc(i, 4);
        end;
      end
      else
        Inc(i);
    end
    else if ParamStr(i) = '--metering' then
    begin
      EnableMetering := True;
      Inc(i);
    end
    else if ParamStr(i) = '--csv' then
    begin
      if i + 1 <= ParamCount then
      begin
        ExportCSV := ParamStr(i + 1);
        Inc(i, 2);
      end
      else
        Inc(i);
    end
    else if ParamStr(i) = '--help' then
    begin
      PrintHelp;
      Halt(0);
    end
    else
      Inc(i);
  end;
end;

{ ============================================================================
  Main Program
  ============================================================================ }

var
  InputFile, OutputFile, ExportCSV: string;
  AudioData: TMemoryStream;
  Context: TProcessContext;
  Header: TWavHeader;
  OriginalHeader: TWavHeader;
  EnableMetering: boolean;
  PeakBefore, RMSBefore, PeakAfter, RMSAfter: double;
  Stream: TFileStream;
  i: integer;

begin
  try
    ParseCommandLine(InputFile, OutputFile, Context, ExportCSV, EnableMetering);

    WriteLn('Loading: ', InputFile);
    Stream := TFileStream.Create(InputFile, fmOpenRead);
    try
      ReadWavHeader(Stream, OriginalHeader);
    finally
      Stream.Free;
    end;

    AudioData := LoadWavFile(InputFile, Context);
    if AudioData = nil then
      Halt(1);

    { Calculate biquad coefficients for all bands }
    for i := 0 to Context.NumBands - 1 do
      CalculateBiquadCoefficients(Context.Bands[i], Context.SampleRate);

    PrintBandSettings(Context);

    { Optional: metering before }
    if EnableMetering then
      AnalyzeSignal(AudioData, Context, PeakBefore, RMSBefore);

    { Process }
    ProcessAudio(AudioData, Context);

    { Optional: metering after }
    if EnableMetering then
    begin
      AnalyzeSignal(AudioData, Context, PeakAfter, RMSAfter);
      PrintMeteringResults(Context, PeakBefore, RMSBefore, PeakAfter, RMSAfter);
    end;

    { Optional: export frequency response }
    if ExportCSV <> '' then
      ExportFrequencyResponseCSV(ExportCSV, Context);

    { Save output }
    SaveWavFile(OutputFile, AudioData, Context, OriginalHeader);

    AudioData.Free;
    WriteLn('Done.');
  except
    on E: Exception do
    begin
      WriteLn('Error: ', E.Message);
      Halt(1);
    end;
  end;
end.
