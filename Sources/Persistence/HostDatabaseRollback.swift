import Foundation
import CoreFoundation
import Darwin
import Security

public enum HostDatabaseRollback {
    public enum RollbackError: Error, CustomStringConvertible {
        case invalid(String)
        public var description: String {
            if case .invalid(let message) = self { return message }
            return "Invalid rollback target or database."
        }
    }

    public static func validate(databaseURL: URL, targetURL: URL, currentBundleURL: URL, currentBundleIdentifier: String) throws -> URL {
        var info = stat()
        guard lstat(databaseURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw RollbackError.invalid("Current database must be an existing regular non-symlink file.")
        }
        var targetInfo = stat()
        guard lstat(targetURL.path, &targetInfo) == 0, (targetInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw RollbackError.invalid("Rollback target must be an existing app directory.")
        }
        let infoURL = targetURL.appendingPathComponent("Contents/Info.plist")
        var plistInfo = stat()
        guard lstat(infoURL.path, &plistInfo) == 0, (plistInfo.st_mode & S_IFMT) == S_IFREG,
              let plist = NSDictionary(contentsOf: infoURL) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == currentBundleIdentifier,
              plist["CFBundleExecutable"] as? String == "RemoteCode",
              let advertised = plist["RC2DatabaseSchemaVersion"] as? NSNumber,
              CFGetTypeID(advertised) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: advertised.objCType)),
              advertised.stringValue == String(Persistence.Schema.currentVersion) else {
            throw RollbackError.invalid("Rollback target metadata must match this channel and exact current schema.")
        }
        let executable = targetURL.appendingPathComponent("Contents/MacOS/RemoteCode")
        var executableInfo = stat()
        guard lstat(executable.path, &executableInfo) == 0, (executableInfo.st_mode & S_IFMT) == S_IFREG,
              (executableInfo.st_mode & S_IXUSR) != 0 else {
            throw RollbackError.invalid("Rollback target executable is missing or invalid.")
        }
        let targetTeam = try signingTeam(bundleURL: targetURL)
        let currentTeam = try signingTeam(bundleURL: currentBundleURL)
        guard targetTeam == currentTeam else { throw RollbackError.invalid("Rollback target signing team differs from running app.") }

        let db = try SQLiteDB(path: databaseURL.path, readonly: true)
        let statement = try db.prepare("SELECT MAX(version), typeof(MAX(version)) FROM schema_meta;")
        guard try statement.step(), let version = statement.columnText(0),
              statement.columnText(1) == "integer",
              let value = Int64(version), value > 0, String(value) == version,
              value <= Int64(advertised.intValue) else {
            throw RollbackError.invalid("Database schema version is invalid or newer than rollback target.")
        }
        return executable
    }

    private static func signingTeam(bundleURL: URL) throws -> String {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw RollbackError.invalid("App signature could not be opened.")
        }
        let checkStatus = SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        guard checkStatus == errSecSuccess else {
            throw RollbackError.invalid("App signature verification failed.")
        }
        var info: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard infoStatus == errSecSuccess, let signingInfo = info as? [String: Any],
              let team = signingInfo[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty,
              let flags = signingInfo[kSecCodeInfoFlags as String] as? NSNumber, (flags.uint32Value & 2) == 0 else {
            throw RollbackError.invalid("App signing team could not be established.")
        }
        return team
    }
}
