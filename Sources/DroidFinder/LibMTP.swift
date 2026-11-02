import CLibMTP
import Foundation

/// libmtp's functions, looked up at runtime. Loading with dlopen instead of linking keeps the
/// app launching on Macs without libmtp (MTP is just unavailable there) and lets the Intel
/// slice build even though Homebrew's libmtp is Apple Silicon only.
final class LibMTP {
    typealias Device = UnsafeMutablePointer<LIBMTP_mtpdevice_t>
    typealias File = UnsafeMutablePointer<LIBMTP_file_t>
    typealias Progress = @convention(c) (UInt64, UInt64, UnsafeRawPointer?) -> Int32

    let initialize: @convention(c) () -> Void
    let detectRawDevices: @convention(c) (
        UnsafeMutablePointer<UnsafeMutablePointer<LIBMTP_raw_device_t>?>?, UnsafeMutablePointer<Int32>?
    ) -> LIBMTP_error_number_t
    let openRawDevice: @convention(c) (UnsafeMutablePointer<LIBMTP_raw_device_t>?) -> Device?
    let releaseDevice: @convention(c) (Device?) -> Void
    let getStorage: @convention(c) (Device?, Int32) -> Int32
    let getModelname: @convention(c) (Device?) -> UnsafeMutablePointer<CChar>?
    let getFilesAndFolders: @convention(c) (Device?, UInt32, UInt32) -> File?
    let getFileMetadata: @convention(c) (Device?, UInt32) -> File?
    let newFile: @convention(c) () -> File?
    let destroyFile: @convention(c) (File?) -> Void
    let getFileToFile: @convention(c) (Device?, UInt32, UnsafePointer<CChar>?, Progress?, UnsafeRawPointer?) -> Int32
    let sendFileFromFile: @convention(c) (Device?, UnsafePointer<CChar>?, File?, Progress?, UnsafeRawPointer?) -> Int32
    let createFolder: @convention(c) (Device?, UnsafeMutablePointer<CChar>?, UInt32, UInt32) -> UInt32
    let deleteObject: @convention(c) (Device?, UInt32) -> Int32
    let setFileName: @convention(c) (Device?, File?, UnsafePointer<CChar>?) -> Int32
    let getThumbnail: @convention(c) (
        Device?, UInt32, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<UInt32>?
    ) -> Int32
    let getErrorstack: @convention(c) (Device?) -> UnsafeMutablePointer<LIBMTP_error_t>?
    let clearErrorstack: @convention(c) (Device?) -> Void

    static let shared: LibMTP? = {
        // The copy bundled in the app first, then Homebrew's on Apple Silicon and Intel.
        let candidates = [
            Bundle.main.privateFrameworksURL?.appendingPathComponent("libmtp.9.dylib").path,
            "/opt/homebrew/opt/libmtp/lib/libmtp.9.dylib",
            "/usr/local/opt/libmtp/lib/libmtp.9.dylib",
        ].compactMap { $0 }
        for path in candidates {
            if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL), let lib = LibMTP(handle) { return lib }
        }
        return nil
    }()

    private init?(_ h: UnsafeMutableRawPointer) {
        func load<T>(_ name: String) -> T? {
            dlsym(h, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard
            let initialize: @convention(c) () -> Void = load("LIBMTP_Init"),
            let detectRawDevices: @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<LIBMTP_raw_device_t>?>?, UnsafeMutablePointer<Int32>?) -> LIBMTP_error_number_t = load("LIBMTP_Detect_Raw_Devices"),
            let openRawDevice: @convention(c) (UnsafeMutablePointer<LIBMTP_raw_device_t>?) -> Device? = load("LIBMTP_Open_Raw_Device_Uncached"),
            let releaseDevice: @convention(c) (Device?) -> Void = load("LIBMTP_Release_Device"),
            let getStorage: @convention(c) (Device?, Int32) -> Int32 = load("LIBMTP_Get_Storage"),
            let getModelname: @convention(c) (Device?) -> UnsafeMutablePointer<CChar>? = load("LIBMTP_Get_Modelname"),
            let getFilesAndFolders: @convention(c) (Device?, UInt32, UInt32) -> File? = load("LIBMTP_Get_Files_And_Folders"),
            let getFileMetadata: @convention(c) (Device?, UInt32) -> File? = load("LIBMTP_Get_Filemetadata"),
            let newFile: @convention(c) () -> File? = load("LIBMTP_new_file_t"),
            let destroyFile: @convention(c) (File?) -> Void = load("LIBMTP_destroy_file_t"),
            let getFileToFile: @convention(c) (Device?, UInt32, UnsafePointer<CChar>?, Progress?, UnsafeRawPointer?) -> Int32 = load("LIBMTP_Get_File_To_File"),
            let sendFileFromFile: @convention(c) (Device?, UnsafePointer<CChar>?, File?, Progress?, UnsafeRawPointer?) -> Int32 = load("LIBMTP_Send_File_From_File"),
            let createFolder: @convention(c) (Device?, UnsafeMutablePointer<CChar>?, UInt32, UInt32) -> UInt32 = load("LIBMTP_Create_Folder"),
            let deleteObject: @convention(c) (Device?, UInt32) -> Int32 = load("LIBMTP_Delete_Object"),
            let setFileName: @convention(c) (Device?, File?, UnsafePointer<CChar>?) -> Int32 = load("LIBMTP_Set_File_Name"),
            let getThumbnail: @convention(c) (Device?, UInt32, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<UInt32>?) -> Int32 = load("LIBMTP_Get_Thumbnail"),
            let getErrorstack: @convention(c) (Device?) -> UnsafeMutablePointer<LIBMTP_error_t>? = load("LIBMTP_Get_Errorstack"),
            let clearErrorstack: @convention(c) (Device?) -> Void = load("LIBMTP_Clear_Errorstack")
        else { return nil }
        self.initialize = initialize
        self.detectRawDevices = detectRawDevices
        self.openRawDevice = openRawDevice
        self.releaseDevice = releaseDevice
        self.getStorage = getStorage
        self.getModelname = getModelname
        self.getFilesAndFolders = getFilesAndFolders
        self.getFileMetadata = getFileMetadata
        self.newFile = newFile
        self.destroyFile = destroyFile
        self.getFileToFile = getFileToFile
        self.sendFileFromFile = sendFileFromFile
        self.createFolder = createFolder
        self.deleteObject = deleteObject
        self.setFileName = setFileName
        self.getThumbnail = getThumbnail
        self.getErrorstack = getErrorstack
        self.clearErrorstack = clearErrorstack
    }
}
