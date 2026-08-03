import Foundation
import Security

public struct SigningIdentitySummary: Sendable {
    public let identifier: String
    public let certificateName: String?
}

public enum SigningIdentityInspector {
    public static func inspect(bundleURL: URL = Bundle.main.bundleURL) -> SigningIdentitySummary? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let values = information as? [CFString: Any],
              let identifier = values[kSecCodeInfoIdentifier] as? String else { return nil }
        let certificates = values[kSecCodeInfoCertificates] as? [SecCertificate]
        let name = certificates?.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        return SigningIdentitySummary(identifier: identifier, certificateName: name)
    }
}
