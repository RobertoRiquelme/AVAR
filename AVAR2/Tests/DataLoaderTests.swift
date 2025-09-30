import Foundation

@main
struct DataLoaderTests {
    static func main() {
        do {
            _ = try DiagramDataLoader.loadScriptOutput(from: "this_file_should_not_exist")
            fatalError("Expected DiagramDataLoader to throw for missing file")
        } catch let error as DiagramLoadingError {
            guard case .fileMissing(let filename) = error else {
                fatalError("Expected fileMissing error, received: \(error)")
            }
            assert(filename == "this_file_should_not_exist", "Filename should be preserved in error")
            print("DataLoaderTests ✅")
        } catch {
            fatalError("Unexpected error type: \(error)")
        }
    }
}
