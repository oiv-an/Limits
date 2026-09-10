import XCTest
import CryptoKit
@testable import LimitsCore

final class SealedCredentialTests: XCTestCase {
    func testEncryptedCredentialRoundTripsWithoutPlaintextOnDisk() throws {
        let device = P256.KeyAgreement.PrivateKey()
        let credential = Data("fixture-credential-only".utf8)
        let envelope = try SealedCredential.seal(credential, devicePublicKey: device.publicKey,
                                                 wrappedDeviceKey: Data("wrapped-fixture".utf8))
        let encoded = try JSONEncoder().encode(envelope)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("fixture-credential-only"))
        let restored = try JSONDecoder().decode(SealedCredential.self, from: encoded)
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: restored.ephemeralPublicKey)
        XCTAssertEqual(try restored.open(sharedSecret: device.sharedSecretFromKeyAgreement(with: peer)), credential)
    }

    func testAnotherDeviceKeyCannotDecrypt() throws {
        let device = P256.KeyAgreement.PrivateKey(), otherDevice = P256.KeyAgreement.PrivateKey()
        let envelope = try SealedCredential.seal(Data("fixture".utf8), devicePublicKey: device.publicKey,
                                                 wrappedDeviceKey: Data())
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: envelope.ephemeralPublicKey)
        XCTAssertThrowsError(try envelope.open(sharedSecret: otherDevice.sharedSecretFromKeyAgreement(with: peer)))
    }

    func testTamperedCiphertextIsRejected() throws {
        let device = P256.KeyAgreement.PrivateKey()
        let envelope = try SealedCredential.seal(Data("fixture".utf8), devicePublicKey: device.publicKey,
                                                 wrappedDeviceKey: Data())
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        var ciphertext = envelope.ciphertext
        ciphertext[ciphertext.count - 1] ^= 1
        fields["ciphertext"] = ciphertext.base64EncodedString()
        let altered = try JSONDecoder().decode(SealedCredential.self, from: JSONSerialization.data(withJSONObject: fields))
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: altered.ephemeralPublicKey)
        XCTAssertThrowsError(try altered.open(sharedSecret: device.sharedSecretFromKeyAgreement(with: peer)))
    }
}
