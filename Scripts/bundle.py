"""Sign and place a locally built UniCodex app bundle."""

import argparse
import ctypes
import fcntl
import hashlib
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import subprocess
import tempfile
import time


IDENTIFIER = "local.codex-api-workbench"
SIGNER = "Codex API Workbench Local Build Signing"
ROOT = Path(__file__).resolve().parents[1]
APPLICATION = Path("/Applications/UniCodex.app")
HELPER = Path("Contents/Helpers/UniCodexCredentials")
HELPER_SOURCE_HASH = Path("Contents/Resources/CredentialHelper.sha256")
SUPPORT = Path.home() / "Library/Application Support/Codex API Workbench"
SIGNING = SUPPORT / "Signing"
REGISTER = ("/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/"
            "LaunchServices.framework/Versions/A/Support/lsregister")
CERTIFICATE_SETTINGS = """[req]
distinguished_name = subject
x509_extensions = signing
prompt = no
[subject]
CN = Codex API Workbench Local Build Signing
[signing]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
"""


def output(*command):
    return subprocess.check_output(command, text=True)


def signing_identity(keychain):
    def find():
        raw = output("/usr/bin/security", "find-identity", "-p", "codesigning", str(keychain))
        return set(re.findall(r'\b([0-9A-F]{40}) "' + re.escape(SIGNER) + r'"', raw))

    identities = find()
    if not identities:
        with tempfile.TemporaryDirectory(prefix="workbench-signing-") as temporary:
            folder = Path(temporary)
            config = folder / "certificate.cnf"
            config.write_text(CERTIFICATE_SETTINGS)
            key, cert, package = (str(folder / name) for name in ("key.pem", "signer.pem", "identity.p12"))
            subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:3072", "-sha256",
                            "-keyout", key, "-out", cert, "-nodes", "-days", "3650", "-config", str(config)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            password = secrets.token_urlsafe(32)
            environment = dict(os.environ, WORKBENCH_LOCAL_CERT_IMPORT_PASSWORD=password)
            subprocess.run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", key, "-in", cert,
                            "-out", package, "-passout", "env:WORKBENCH_LOCAL_CERT_IMPORT_PASSWORD"], check=True, env=environment)
            imported = subprocess.run(["/usr/bin/security", "import", package, "-k", str(keychain),
                                       "-P", password, "-T", "/usr/bin/codesign"], capture_output=True)
            if imported.returncode != 0:
                raise RuntimeError("Could not import the local signing identity. Unlock your login keychain and retry.")
        identities = find()
    if len(identities) != 1:
        raise RuntimeError("Expected one UniCodex signing identity in the dedicated keychain.")
    return identities.pop()


def verify_signature(bundle, identity):
    requirement = f'identifier "{IDENTIFIER}" and certificate leaf = H"{identity}"'
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + requirement, str(bundle)], check=True)


def prepare_credential_helper(bundle, identity, keychain):
    source = ROOT / "Sources/Credentials/ProviderCredentialHelper.swift"
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    previous = APPLICATION / HELPER
    executable = bundle / HELPER
    executable.parent.mkdir(parents=True, exist_ok=True)
    requirement = f'identifier "{IDENTIFIER}.credential-helper" and certificate leaf = H"{identity}"'
    verify = ["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + requirement]
    marker = APPLICATION / HELPER_SOURCE_HASH
    if previous.is_file() and marker.is_file() and marker.read_text() == digest:
        subprocess.run([*verify, str(previous)], check=True)
        shutil.copy2(previous, executable)
    else:
        target = output("/usr/bin/uname", "-m").strip() + "-apple-macosx14.0"
        subprocess.run(["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-target", target, "-O",
                        "-suppress-warnings", str(source), "-o", str(executable)], check=True)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, "--keychain", str(keychain),
                        "--identifier", IDENTIFIER + ".credential-helper", "--options", "runtime",
                        "--timestamp=none", "--requirements", "=designated => " + requirement, str(executable)], check=True)
    subprocess.run([*verify, str(executable)], check=True)
    (bundle / HELPER_SOURCE_HASH).write_text(digest)


def sign(bundle):
    SIGNING.mkdir(mode=0o700, exist_ok=True)
    if SIGNING.is_symlink():
        raise RuntimeError("The signing directory is a symbolic link.")
    helper = SIGNING / "signing-keychain"
    keychain = SIGNING / "workbench.keychain"
    if not helper.is_file():
        with tempfile.TemporaryDirectory(dir=SIGNING, prefix=".prepare-") as temporary:
            executable = Path(temporary) / "signing-keychain"
            subprocess.run(["/usr/bin/xcrun", "swiftc", str(ROOT / "Scripts/SigningKeychain.swift"),
                            "-suppress-warnings", "-o", str(executable)], check=True)
            executable.chmod(0o700)
            executable.rename(helper)
    subprocess.run([str(helper), "open", str(keychain)], check=True)
    try:
        identity = signing_identity(keychain)
        fingerprint = SIGNING / "certificate-fingerprint"
        if fingerprint.is_file() and fingerprint.read_text() != identity:
            raise RuntimeError("The local UniCodex signing identity has changed.")
        prepare_credential_helper(bundle, identity, keychain)
        requirement = f'designated => identifier "{IDENTIFIER}" and certificate leaf = H"{identity}"'
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, "--keychain", str(keychain),
                        "--options", "runtime", "--timestamp=none", "--requirements", "=" + requirement, str(bundle)], check=True)
        verify_signature(bundle, identity)
        fingerprint.write_text(identity)
    finally:
        subprocess.run([str(helper), "lock", str(keychain)], check=True)


def is_unicodex(bundle):
    if bundle.is_symlink() or not bundle.is_dir():
        return False
    try:
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException):
        return False
    return info.get("CFBundleIdentifier") == IDENTIFIER and info.get("CFBundleExecutable") == "APIWorkbench"



def running_app(destination):
    executable = str(destination / "Contents/MacOS/APIWorkbench")
    snapshot = output("/bin/ps", "-axww", "-o", "pid=,comm=")
    for line in snapshot.splitlines():
        columns = line.strip().split(maxsplit=1)
        if len(columns) != 2 or columns[1] != executable:
            continue
        process = subprocess.run(
            ["/bin/ps", "-ww", "-p", columns[0], "-o", "args="],
            capture_output=True,
            text=True,
        )
        if process.returncode == 0 and process.stdout.strip() not in {
            f"{executable} --mcp",
            f"{executable} --mcp-config",
        }:
            return True
    return False


def exchange(first, second):
    library = ctypes.CDLL(None, use_errno=True)
    swap = library.renameatx_np
    swap.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    swap.restype = ctypes.c_int
    at_fdcwd = -2
    rename_swap = 2
    if swap(at_fdcwd, os.fsencode(first), at_fdcwd, os.fsencode(second), rename_swap) != 0:
        raise OSError(ctypes.get_errno(), "Could not replace the UniCodex bundle atomically.")


def place_bundle(bundle, destination):
    identity = (SIGNING / "certificate-fingerprint").read_text()
    if re.fullmatch(r"[0-9A-F]{40}", identity) is None:
        raise RuntimeError("The stored signing fingerprint is invalid.")
    verify_signature(bundle, identity)
    replacing = destination.exists() or destination.is_symlink()
    if replacing and not is_unicodex(destination):
        raise RuntimeError(f"An unrelated item occupies {destination}.")
    if running_app(destination):
        print("Quit UniCodex to finish installing the update.", flush=True)
        while running_app(destination):
            time.sleep(1)
    if replacing:
        exchange(bundle, destination)
    else:
        bundle.rename(destination)
    try:
        verify_signature(destination, identity)
    except Exception:
        if replacing:
            exchange(bundle, destination)
        else:
            destination.rename(bundle)
        raise
    if destination == APPLICATION:
        subprocess.run([REGISTER, "-f", str(destination)], check=False, capture_output=True)
    print(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("sign", "install", "stage"))
    parser.add_argument("bundle", type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    SUPPORT.mkdir(mode=0o700, parents=True, exist_ok=True)
    if SUPPORT.is_symlink():
        raise RuntimeError("The UniCodex data directory is a symbolic link.")
    if not is_unicodex(args.bundle):
        raise RuntimeError("Expected a UniCodex app bundle.")
    with (SUPPORT / ".release-lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.action == "sign":
            sign(args.bundle)
        else:
            destination = APPLICATION if args.action == "install" else ROOT / "build/UniCodex.app"
            place_bundle(args.bundle, destination)


if __name__ == "__main__":
    main()
