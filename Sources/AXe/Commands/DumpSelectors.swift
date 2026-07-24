import ArgumentParser
import Foundation
import ObjectiveC.runtime

/// Hidden spike tool: enumerate an Objective-C class's full method list at
/// runtime. The point: the interesting AX/CoreSimulator API surface lives in
/// private frameworks whose headers ship only partially in idb's vendored
/// set — but axe already loads the real frameworks, so the runtime can be
/// asked directly, no dyld-shared-cache extraction required.
struct DumpSelectors: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump-selectors",
        shouldDisplay: false
    )

    @Argument(help: "Objective-C class name to enumerate.")
    var className: String

    @Flag(name: .customLong("meta"), help: "Dump class (meta) methods instead of instance methods.")
    var meta: Bool = false

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        guard var cls: AnyClass = NSClassFromString(className) else {
            throw CLIError(errorDescription: "Class not found in the loaded runtime: \(className)")
        }
        if meta {
            guard let metaClass = object_getClass(cls) else {
                throw CLIError(errorDescription: "No metaclass for \(className)")
            }
            cls = metaClass
        }

        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else {
            print("(no methods)")
            return
        }
        defer { free(methods) }
        var names: [String] = []
        for i in 0..<Int(count) {
            names.append(NSStringFromSelector(method_getName(methods[i])))
        }
        for name in names.sorted() {
            print(name)
        }
    }
}
