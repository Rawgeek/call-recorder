import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

/// The speaker script hands pyannote audio that pyannote can crop without TorchCodec.
///
/// The 2026-10-23 processing job F4F2640B was left failed after three attempts: the embedder was
/// given a file name, and the installed pyannote asked TorchCodec to crop it, which this runtime
/// does not have. These tests run the shipping script against the installed pyannote reader and
/// generated audio, so the crop boundary itself answers whether the run can proceed.
struct DiarizationWaveformTests {
    @Test(
        "the detected route hands each ten-second chunk to pyannote as a waveform",
        .enabled(if: TestEnvironment.canRunDiarizationCrop)
    )
    func detectedRouteUsesWaveformChunks() throws {
        try runDriver(mode: "detected")
    }

    @Test(
        "a window that starts later in the call reads the audio at its absolute time",
        .enabled(if: TestEnvironment.canRunDiarizationCrop)
    )
    func windowStartKeepsAbsoluteAudio() throws {
        try runDriver(mode: "window")
    }

    @Test(
        "the exact-count route decodes once and hands pyannote a waveform",
        .enabled(if: TestEnvironment.canRunDiarizationCrop)
    )
    func exactCountUsesOneWaveform() throws {
        try runDriver(mode: "count")
    }

    @Test(
        "the runtime check needs the shipped decoder, not TorchCodec",
        .enabled(if: TestEnvironment.canRunDiarizationCrop)
    )
    func runtimeCheckUsesShippedDecoder() throws {
        try runDriver(mode: "check")
    }

    private func runDriver(mode: String) throws {
        guard let python = TestEnvironment.diarizationCropPython,
            let sitePackages = TestEnvironment.speakerSitePackages,
            let script = TestEnvironment.diarizationScript
        else {
            Issue.record("the speaker crop runtime is missing; check its configuration")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            Issue.record("the speaker crop interpreter is not executable: \(python.path)")
            return
        }
        let reader = sitePackages.appending(path: "pyannote/audio/core/io.py")
        guard FileManager.default.fileExists(atPath: reader.path) else {
            Issue.record("the speaker crop packages are missing: \(sitePackages.path)")
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "diarization-waveform-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let driver = directory.appending(path: "driver.py")
        try driverScript.write(to: driver, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = python
        process.arguments = [driver.path, script.path, sitePackages.path, mode, directory.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let reported = String(decoding: data, as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(reported)")
    }

    /// One harness for all four routes, so each scenario shares the real reader and real fixtures.
    private var driverScript: String {
        """
        import importlib.util
        import math
        import sys
        import types
        import warnings
        import wave

        import numpy as np
        import torch

        script_path, site_path, mode, work = sys.argv[1:5]
        sys.path.append(site_path)

        # The reader imports torchaudio for resampling, which the waveform path never does.
        torchaudio = types.ModuleType("torchaudio")
        functional = types.ModuleType("torchaudio.functional")
        functional.resample = lambda waveform, *args, **kwargs: waveform
        torchaudio.functional = functional
        sys.modules.setdefault("torchaudio", torchaudio)

        audio_package = types.ModuleType("pyannote.audio")
        audio_package.__path__ = [site_path + "/pyannote/audio"]
        core_package = types.ModuleType("pyannote.audio.core")
        core_package.__path__ = [site_path + "/pyannote/audio/core"]
        sys.modules["pyannote.audio"] = audio_package
        sys.modules["pyannote.audio.core"] = core_package

        spec = importlib.util.spec_from_file_location(
            "pyannote.audio.core.io", site_path + "/pyannote/audio/core/io.py"
        )
        pyannote_io = importlib.util.module_from_spec(spec)
        sys.modules["pyannote.audio.core.io"] = pyannote_io
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            spec.loader.exec_module(pyannote_io)
        # The confirmed failure is the codec-free branch, so a machine that has a working
        # TorchCodec still checks the path this job took.
        pyannote_io.TORCHCODEC_AVAILABLE = False

        from pyannote.core import Segment, SlidingWindowFeature

        spec = importlib.util.spec_from_file_location("diarize", script_path)
        diarize = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(diarize)

        sample_rate = diarize.SAMPLING_RATE
        chunk_samples = int(round(diarize.CHUNK_SECONDS * sample_rate))
        read_calls = []

        def write_fixture(name, seconds):
            path = work + "/" + name
            count = int(round(seconds * sample_rate))
            values = ((np.arange(count) % 19997) - 10000).astype("<i2")
            with wave.open(path, "wb") as output:
                output.setnchannels(1)
                output.setsampwidth(2)
                output.setframerate(sample_rate)
                output.writeframes(values.tobytes())
            return diarize.Path(path)

        def expected(position):
            return float((position % 19997) - 10000) / 32768.0

        def decode(path):
            read_calls.append(str(path))
            with wave.open(str(path), "rb") as source:
                if source.getnchannels() != 1 or source.getframerate() != sample_rate:
                    raise AssertionError("the fixture is not mono 16 kHz")
                frames = source.readframes(source.getnframes())
            return np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0

        class Embedder:
            def __init__(self):
                self.reader = pyannote_io.Audio(sample_rate=sample_rate, mono="downmix")
                self.crops = []
                self.calls = []
                self.count_calls = 0
                self.ordinal = 0

            def _reject(self, file):
                # Hand the value to the real reader, so the failure is the production one.
                self.reader.crop(file, Segment(0, 1), mode="pad")
                raise AssertionError("the reader accepted %r" % (type(file),))

            def get_embeddings(self, file, binary_segmentations, exclude_overlap=False, hook=None):
                if not isinstance(file, dict) or "waveform" not in file:
                    self._reject(file)
                if not exclude_overlap:
                    raise AssertionError("overlapping speech was not excluded")
                if file["sample_rate"] != sample_rate:
                    raise AssertionError("the waveform lost its sampling rate")
                data = np.asarray(binary_segmentations.data, dtype=np.float32)
                chunks, frames, voices = data.shape
                self.calls.append(chunks)
                result = np.zeros((chunks, voices, diarize.EMBEDDING_DIMENSION))
                alone_frames = (data.sum(axis=2, keepdims=True) < 2)
                min_frames = 2
                for index, (segment, masks) in enumerate(binary_segmentations):
                    ordinal = self.ordinal
                    self.ordinal += 1
                    waveform, rate = self.reader.crop(file, segment, mode="pad")
                    if rate != sample_rate:
                        raise AssertionError("the crop came back at %r Hz" % (rate,))
                    if tuple(waveform.shape) != (1, chunk_samples):
                        raise AssertionError("the crop is %r, not mono ten seconds" % (waveform.shape,))
                    samples = waveform[0].numpy()
                    real = min(
                        chunk_samples,
                        max(0, file["waveform"].shape[1] - int(round(segment.start * sample_rate))),
                    )
                    self.crops.append(
                        {
                            "start": segment.start,
                            "first": float(samples[0]),
                            "real": real,
                            "last_real": float(samples[real - 1]) if real else float("nan"),
                            "pad_sample": float(samples[real]) if real < chunk_samples else 0.0,
                            "last": float(samples[-1]),
                            "shape": tuple(waveform.shape),
                            "rate": rate,
                        }
                    )
                    for voice in range(voices):
                        mask = np.nan_to_num(masks[:, voice], nan=0.0).astype(np.float32)
                        clean = mask * alone_frames[index, :, 0]
                        used = clean if clean.sum() > min_frames else mask
                        active = used > 0
                        if not active.any():
                            result[index, voice] = np.nan
                            continue
                        per_sample = np.repeat(active, int(round(1 / diarize.FRAME_SECONDS)))
                        per_sample = per_sample[: len(samples)]
                        result[index, voice, 0] = float(samples[: len(per_sample)][per_sample].mean())
                        result[index, voice, 1] = float(active.sum()) / 1000.0
                        result[index, voice, 2] = float(clean.sum() > min_frames)
                        result[index, voice, 10 + ordinal] = 1.0
                return result

            def __call__(self, file, num_speakers=None, **kwargs):
                if not isinstance(file, dict) or "waveform" not in file:
                    self._reject(file)
                if num_speakers != 2:
                    raise AssertionError("the count did not reach the pipeline")
                self.count_calls += 1
                seconds = file["waveform"].shape[1] / file["sample_rate"]
                for index in range(math.ceil(seconds / diarize.CHUNK_SECONDS)):
                    start = index * diarize.CHUNK_SECONDS
                    waveform, rate = self.reader.crop(
                        file, Segment(start, start + diarize.CHUNK_SECONDS), mode="pad"
                    )
                    if rate != sample_rate or tuple(waveform.shape) != (1, chunk_samples):
                        raise AssertionError("the count route cropped %r at %r" % (waveform.shape, rate))
                    self.crops.append(
                        {
                            "start": start,
                            "first": float(waveform[0, 0]),
                            "real": min(
                                chunk_samples,
                                max(0, file["waveform"].shape[1] - int(round(start * sample_rate))),
                            ),
                            "last": float(waveform[0, -1]),
                            "shape": tuple(waveform.shape),
                            "rate": rate,
                        }
                    )

                class Track:
                    def __init__(self, start, end):
                        self.start = start
                        self.end = end

                class Diarization:
                    def labels(self):
                        return ["SPEAKER_00", "SPEAKER_01"]

                    def itertracks(self, yield_label=False):
                        for start, end, label in (
                            (0.0, 9.0, "SPEAKER_00"),
                            (9.0, 18.0, "SPEAKER_01"),
                            (18.0, 25.0, "SPEAKER_00"),
                        ):
                            yield Track(start, end), None, label

                first = np.zeros(diarize.EMBEDDING_DIMENSION)
                first[0] = 3.0
                second = np.zeros(diarize.EMBEDDING_DIMENSION)
                second[7] = 4.0

                class Output:
                    exclusive_speaker_diarization = Diarization()
                    speaker_diarization = Diarization()
                    speaker_embeddings = np.stack([first, second])

                return Output()

        def install():
            diarize.read_audio = decode
            diarize.load_turn_model = lambda: (object(), object())
            diarize.load_embedder = lambda: embedder
            diarize.on_accelerator = lambda module, torch_module: None

        def activity_of(duration, voices):
            return np.zeros((int(round(duration / diarize.FRAME_SECONDS)), voices), dtype=np.float32)

        def check_speakers(payload, labels):
            got = [speaker["speaker"] for speaker in payload["speakers"]]
            if got != labels:
                raise AssertionError("the voices came out as %r" % (got,))
            for speaker in payload["speakers"]:
                values = np.asarray(speaker["embedding"])
                if values.shape != (diarize.EMBEDDING_DIMENSION,):
                    raise AssertionError("a voice print is %r" % (values.shape,))
                if not np.all(np.isfinite(values)) or abs(float(np.linalg.norm(values)) - 1.0) > 1e-6:
                    raise AssertionError("a voice print is not a unit centroid")

        if mode == "detected":
            path = write_fixture("detected.wav", 25.0)
            embedder = Embedder()
            install()
            activity = activity_of(25.0, 2)
            activity[0:1000, 0] = 1.0
            activity[500:1000, 1] = 1.0
            activity[1000:2000, 0] = 1.0
            activity[1000:1500, 1] = 1.0
            activity[2000:2500, 1] = 1.0
            turns = [
                {"Start": 0.0, "End": 9.0, "Speaker": 0},
                {"Start": 5.0, "End": 9.0, "Speaker": 1},
                {"Start": 10.0, "End": 19.0, "Speaker": 0},
                {"Start": 20.0, "End": 24.9, "Speaker": 1},
            ]
            diarize.speech_activity = lambda processor, model, samples: (activity, turns)

            payload = diarize.separate_by_detector(path)
            if len(read_calls) != 1:
                raise AssertionError("the call was decoded %d times" % len(read_calls))
            if embedder.calls != [1, 1, 1]:
                raise AssertionError("the embedder read %r chunks per call" % (embedder.calls,))
            if [crop["first"] for crop in embedder.crops] != [
                expected(0), expected(160000), expected(320000)
            ]:
                raise AssertionError("a chunk read the wrong audio: %r" % (embedder.crops,))
            for crop in embedder.crops:
                if crop["shape"] != (1, chunk_samples) or crop["rate"] != sample_rate:
                    raise AssertionError("a chunk is not mono 16 kHz: %r" % (crop,))
            # The last chunk holds five seconds of the call and five seconds of padding.
            third = embedder.crops[2]
            if third["real"] != 80000:
                raise AssertionError("the last chunk read %d samples" % third["real"])
            if third["pad_sample"] != 0.0 or third["last"] != 0.0:
                raise AssertionError("the last chunk was not padded with silence: %r" % (third,))
            if third["last_real"] != expected(320000 + 80000 - 1):
                raise AssertionError("the last chunk read the wrong tail: %r" % (third,))
            check_speakers(payload, ["SPEAKER_00", "SPEAKER_01"])
            if [segment["speaker"] for segment in payload["segments"]][:1] != ["SPEAKER_00"]:
                raise AssertionError("the turns lost their voices: %r" % (payload["segments"],))
            # The first voice was measured over the two chunks where it talks alone, and the second
            # only over the third: the overlapped chunks are not allowed to shape its centroid.
            by_label = {speaker["speaker"]: np.asarray(speaker["embedding"]) for speaker in payload["speakers"]}
            first = by_label["SPEAKER_00"]
            second = by_label["SPEAKER_01"]
            if not (first[10] > 0 and first[11] > 0 and abs(first[12]) < 1e-9):
                raise AssertionError("the first voice used the wrong chunks: %r" % (first[[10, 11, 12]],))
            if not (abs(second[10]) < 1e-9 and abs(second[11]) < 1e-9 and second[12] > 0):
                raise AssertionError("the second voice used the wrong chunks: %r" % (second[[10, 11, 12]],))
            print("ok detected")

            # A stretch with no speech at all keeps no voices, and the embedder is not asked for a
            # centroid of a silence that the turn model never found.
            diarize.speech_activity = lambda processor, model, samples: (activity_of(25.0, 2), [])
            silent = diarize.separate_by_detector(path)
            if silent["segments"] or silent["speakers"]:
                raise AssertionError("an empty stretch produced voices: %r" % (silent,))
            print("ok no-activity")

        elif mode == "window":
            path = write_fixture("window.wav", 500.0)
            embedder = Embedder()
            install()
            diarize.window_slices = lambda count: [(480.0, 480 * sample_rate, 500 * sample_rate)]
            activity = activity_of(20.0, 1)
            activity[:, 0] = 1.0
            turns = [{"Start": 0.0, "End": 19.0, "Speaker": 0}]
            diarize.speech_activity = lambda processor, model, samples: (activity, turns)

            payload = diarize.separate_by_detector(path)
            if embedder.calls != [1, 1]:
                raise AssertionError("the embedder read %r chunks per call" % (embedder.calls,))
            if [crop["first"] for crop in embedder.crops] != [
                expected(480 * sample_rate), expected(490 * sample_rate)
            ]:
                raise AssertionError("the window read audio from the wrong time: %r" % (embedder.crops,))
            check_speakers(payload, ["SPEAKER_00"])
            if any(crop["first"] == expected(0) for crop in embedder.crops):
                raise AssertionError("the window read the start of the call")
            print("ok window")

        elif mode == "count":
            path = write_fixture("count.wav", 25.0)
            embedder = Embedder()
            install()
            payload = diarize.separate_into_count(path, 2)
            if len(read_calls) != 1:
                raise AssertionError("the count route decoded %d times" % len(read_calls))
            if embedder.count_calls != 1:
                raise AssertionError("the pipeline was applied %d times" % embedder.count_calls)
            if len(embedder.crops) != 3:
                raise AssertionError("the count route cropped %d chunks" % len(embedder.crops))
            if [crop["start"] for crop in embedder.crops] != [0.0, 10.0, 20.0]:
                raise AssertionError("the count route cropped at %r" % (embedder.crops,))
            if [crop["first"] for crop in embedder.crops] != [
                expected(0), expected(160000), expected(320000)
            ]:
                raise AssertionError("the count route read the wrong audio: %r" % (embedder.crops,))
            check_speakers(payload, ["SPEAKER_00", "SPEAKER_01"])
            if [segment["speaker"] for segment in payload["segments"]] != [
                "SPEAKER_00", "SPEAKER_01", "SPEAKER_00"
            ]:
                raise AssertionError("the count turns changed: %r" % (payload["segments"],))
            third = embedder.crops[2]
            if third["real"] != 80000 or third["last"] != 0.0:
                raise AssertionError("the count route did not pad the last chunk: %r" % (third,))
            print("ok count")

        elif mode == "check":
            embedder = Embedder()
            install()
            receipt = diarize.check_audio_decoder()
            if len(read_calls) != 1:
                raise AssertionError("the check decoded %d files" % len(read_calls))
            if receipt["samples"] != 24000 or receipt["stretch"] != 24000:
                raise AssertionError("the check read the wrong generated audio: %r" % (receipt,))
            if receipt["cropShape"] != [1, chunk_samples] or receipt["sampleRate"] != sample_rate:
                raise AssertionError("the check did not exercise the real crop: %r" % (receipt,))
            if receipt["paddedSamples"] != chunk_samples - 24000:
                raise AssertionError("the check did not prove the crop pads: %r" % (receipt,))

            # A crop that breaks has to fail the check, rather than pass on the decode alone.
            real_reader = pyannote_io.Audio

            class Broken:
                def __init__(self, *args, **kwargs):
                    pass

                def crop(self, *args, **kwargs):
                    raise RuntimeError("broken crop")

            pyannote_io.Audio = Broken
            try:
                try:
                    diarize.check_audio_decoder()
                except RuntimeError as error:
                    if "broken crop" not in str(error):
                        raise
                else:
                    raise AssertionError("the check passed with a broken crop")
            finally:
                pyannote_io.Audio = real_reader
            print("ok check")

        else:
            raise SystemExit("unknown mode " + mode)
        """
    }
}
