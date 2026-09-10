import Foundation
import SharedAccountingCore

let input: Data
if CommandLine.arguments.count == 2 {
    input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
} else {
    input = FileHandle.standardInput.readDataToEndOfFile()
}
FileHandle.standardOutput.write(SharedAccountingJSON.report(input))
FileHandle.standardOutput.write(Data([10]))
