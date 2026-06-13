import Foundation
import AppLifecycleSupport

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: LifecycleSignalProbe <directory>\n".utf8))
    exit(64)
}

let directory = URL(fileURLWithPath: args[1], isDirectory: true)
let recorder = AppLifecycleRecorder(directory: directory)
recorder.beginRun()
recorder.installSignalHandlers()

FileHandle.standardOutput.write(Data("ready\n".utf8))
while true {
    sleep(1)
}
