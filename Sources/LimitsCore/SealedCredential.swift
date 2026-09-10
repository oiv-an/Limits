import Foundation
import CryptoKit

/// The private-key blob is wrapped by this Mac's Secure Enclave, never a plaintext private key.
public struct SealedCredential: Codable {
    public let version: Int
    public let wrappedDeviceKey: Data
    public let ephemeralPublicKey: Data
    public let salt: Data
    public let ciphertext: Data

    private static let context = Data("pro.ivol.Limits.Claude.TouchID.v1".utf8)

    public static func seal(_ credential: Data, devicePublicKey: P256.KeyAgreement.PublicKey,
                            wrappedDeviceKey: Data) throws -> Self {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: devicePublicKey)
        let salt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                 sharedInfo: context, outputByteCount: 32)
        let box = try AES.GCM.seal(credential, using: key, authenticating: context)
        return Self(version: 1, wrappedDeviceKey: wrappedDeviceKey,
                    ephemeralPublicKey: ephemeral.publicKey.x963Representation, salt: salt, ciphertext: box.combined!)
    }

    public func open(sharedSecret: SharedSecret) throws -> Data {
        guard version == 1, salt.count == 32 else { throw UsageError.invalidResponse }
        let key = sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                       sharedInfo: Self.context, outputByteCount: 32)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key, authenticating: Self.context)
    }
}
