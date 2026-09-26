import Foundation
import TokEngine

// Tok latency harness: real capture, real Live and REST routes, synthesized key presses,
// TTS clips played through the built-in speakers. No hotkey, clipboard, or paste.
// Results: build/harness/runs/<run>.jsonl and build/harness/history.db.

let options: HarnessOptions
do {
  options = try HarnessOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(64)
}

var clips: [HarnessClip]
do {
  clips = try HarnessClip.load(
    directory: options.root.appendingPathComponent("build/harness/clips"))
} catch {
  FileHandle.standardError.write(Data("No clip bank. Run `make harness-clips` first.\n".utf8))
  exit(66)
}
if !options.only.isEmpty {
  clips = clips.filter { clip in options.only.contains { clip.phraseId.hasPrefix($0) } }
}
guard !clips.isEmpty else {
  FileHandle.standardError.write(Data("The clip bank is empty. Run `make harness-clips`.\n".utf8))
  exit(66)
}

let apiKey = HarnessSettings.apiKey(root: options.root)
guard !apiKey.isEmpty else {
  FileHandle.standardError.write(
    Data("GEMINI_API_KEY is not set in the environment or .env.\n".utf8))
  exit(78)
}

let owner = HarnessSettings.ownerValues()
let buildId = ProcessInfo.processInfo.environment["TOK_BUILD_ID"] ?? "harness"
let vocabulary = HarnessSettings.vocabularyText(owner: owner)

if options.direct {
  let direct: DirectRunner
  do {
    direct = try DirectRunner(
      options: options, clips: clips, owner: owner, apiKey: apiKey, vocabulary: vocabulary,
      buildId: buildId)
  } catch {
    FileHandle.standardError.write(Data("Cannot start direct mode: \(error)\n".utf8))
    exit(73)
  }
  let directSleep = SleepAssertion(reason: "Tok latency harness direct run")
  signal(SIGINT, SIG_IGN)
  let directStop = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
  directStop.setEventHandler {
    print("Stopping after the turns in flight.")
    direct.requestStop()
  }
  directStop.resume()
  Thread.detachNewThread {
    let status = direct.run()
    directSleep.release()
    DispatchQueue.main.async { exit(status) }
  }
  dispatchMain()
}

guard let route = AudioRoute.current() else {
  FileHandle.standardError.write(Data("No audio output device.\n".utf8))
  exit(69)
}
if let problem = route.problem {
  FileHandle.standardError.write(Data("Cannot start: \(problem).\n".utf8))
  exit(69)
}

let runner: HarnessRunner
do {
  runner = try HarnessRunner(
    options: options, clips: clips, owner: owner, apiKey: apiKey,
    vocabulary: vocabulary, buildId: buildId)
} catch {
  FileHandle.standardError.write(
    Data("Cannot create run files: \(error.localizedDescription)\n".utf8))
  exit(73)
}

let meanGap = 0.40 * 16.5 + 0.17 * 59 + 0.43 * 102.5
let meanClip = clips.map { $0.speechOffsetS - $0.speechOnsetS }.reduce(0, +) / Double(clips.count)
let turns = Double(options.turnsPerArm * options.arms.count)
let hours = turns * (meanGap * options.gapScale + meanClip + 1.5) / 3600
print(
  String(
    format:
      "%d clips, output %@ at %@. About %.1f h for %.0f turns. Ctrl-C stops after the current turn.",
    clips.count, route.name, route.volume.map { "\(Int($0 * 100))%" } ?? "unknown volume", hours,
    turns))

let sleepAssertion = SleepAssertion(reason: "Tok latency harness run")
var signalSources: [DispatchSourceSignal] = []
var stopSignals = 0
for number in [SIGINT, SIGTERM] {
  signal(number, SIG_IGN)
  let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
  source.setEventHandler {
    stopSignals += 1
    if stopSignals > 1 { exit(130) }
    print("Stopping after the current turn. Press Ctrl-C again to quit now.")
    runner.requestStop()
  }
  source.resume()
  signalSources.append(source)
}

Thread.detachNewThread {
  let status = runner.run()
  sleepAssertion.release()
  DispatchQueue.main.async { exit(status) }
}
dispatchMain()
