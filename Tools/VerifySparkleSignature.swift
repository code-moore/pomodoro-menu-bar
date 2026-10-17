import CryptoKit
import Foundation

// Verifies a Sparkle appcast signature the same way Sparkle does: an Ed25519
// signature over the exact archive bytes, checked against the public key baked
// into the app's Info.plist.
//
//   swift Tools/VerifySparkleSignature.swift <publicKeyB64> <signatureB64> <archive>

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(
        Data("usage: VerifySparkleSignature <publicKeyB64> <signatureB64> <archive>\n".utf8)
    )
    exit(64)
}

guard
    let keyData = Data(base64Encoded: args[1]),
    let signature = Data(base64Encoded: args[2]),
    let archive = FileManager.default.contents(atPath: args[3])
else {
    print("FAILED: could not decode the key, signature, or read the archive")
    exit(2)
}

do {
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let ok = publicKey.isValidSignature(signature, for: archive)
    print(ok ? "VALID" : "INVALID")
    exit(ok ? 0 : 1)
} catch {
    print("FAILED: bad public key — \(error)")
    exit(3)
}
