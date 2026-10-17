#!/usr/bin/env python3
"""Local Ad Hoc signing preflight and exported IPA verification; no portal writes."""
import argparse
import datetime
import os
import hashlib
import json
import pathlib
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile


def run(*args):
  result = subprocess.run(args, capture_output=True)
  if result.returncode:
    raise RuntimeError(args[0] + " failed: " + result.stderr.decode(errors="replace")[-2000:])
  return result.stdout


def decode_profile(path):
  return plistlib.loads(run("security", "cms", "-D", "-i", str(path)))


def validate_profile(profile, udid, now=None):
  now = now or datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
  if profile.get("ExpirationDate", now) <= now or profile.get("CreationDate", now) > now:
    raise ValueError("Provisioning profile is expired or not yet valid")
  entitlements = profile.get("Entitlements", {})
  devices = profile.get("ProvisionedDevices", [])
  if "iOS" not in profile.get("Platform", []):
    raise ValueError("An iOS provisioning profile is required")
  if not devices or udid not in devices:
    raise ValueError("Target device is not in the provisioning profile")
  if entitlements.get("get-task-allow") is not False or profile.get("ProvisionsAllDevices"):
    raise ValueError("Expected an Ad Hoc distribution profile, not development/enterprise")
  teams = profile.get("TeamIdentifier", [])
  app_identifier = entitlements.get("application-identifier", "")
  prefixes = profile.get("ApplicationIdentifierPrefix", [])
  if len(teams) != 1 or not re.fullmatch(r"[A-Z0-9]{10}", teams[0]):
    raise ValueError("Invalid provisioning team")
  if not prefixes or not app_identifier.startswith(prefixes[0] + "."):
    raise ValueError("Invalid application identifier prefix")
  bundle_id = app_identifier[len(prefixes[0]) + 1:]
  if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
    raise ValueError("An explicit, safe bundle identifier is required")
  if entitlements.get("com.apple.developer.team-identifier") != teams[0]:
    raise ValueError("Profile entitlement team mismatch")
  uuid = profile.get("UUID", "")
  if not re.fullmatch(r"[A-Fa-f0-9-]{36}", uuid):
    raise ValueError("Invalid provisioning profile UUID")
  certificates = {hashlib.sha1(c).hexdigest().upper() for c in profile.get("DeveloperCertificates", [])}
  if not certificates:
    raise ValueError("Profile has no signing certificate")
  return {"bundleId": bundle_id, "team": teams[0], "uuid": uuid,
          "applicationIdentifier": app_identifier, "certificates": sorted(certificates)}


def validate_pair(app, widget):
  if app["team"] != widget["team"]:
    raise ValueError("App and Widget must use the same team")
  if not widget["bundleId"].startswith(app["bundleId"] + "."):
    raise ValueError("Widget identifier must be nested under the App identifier")
  if not set(app["certificates"]) & set(widget["certificates"]):
    raise ValueError("App and Widget have no common distribution certificate")


def prepare(args):
  profiles = [pathlib.Path(args.app_profile).resolve(), pathlib.Path(args.widget_profile).resolve()]
  facts = [validate_profile(decode_profile(p), args.udid) for p in profiles]
  app, widget = facts
  validate_pair(app, widget)
  identities = run("security", "find-identity", "-v", "-p", "codesigning").decode()
  common = set(app["certificates"]) & set(widget["certificates"])
  available = [c for c in sorted(common) if re.search(r"\b" + c + r'\s+"Apple Distribution:', identities)]
  if not available:
    raise ValueError("No valid local Apple Distribution identity/private key matches both profiles")
  identity = available[0]
  work = pathlib.Path(args.work)
  work.mkdir(parents=True, exist_ok=False)
  # Xcode 16+ profile location. Do not overwrite a different existing profile.
  installed = pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
  installed.mkdir(parents=True, exist_ok=True)
  for source, fact in zip(profiles, facts):
    destination = installed / (fact["uuid"] + ".mobileprovision")
    if destination.exists() and destination.read_bytes() != source.read_bytes():
      raise ValueError("An installed profile with this UUID has different contents")
    if not destination.exists():
      with destination.open("xb") as f:
        f.write(source.read_bytes())
      destination.chmod(0o600)
  config = [
    "CODE_SIGNING_ALLOWED = YES", "CODE_SIGNING_REQUIRED = YES", "CODE_SIGN_STYLE = Manual",
    "CODE_SIGN_IDENTITY = " + identity, "DEVELOPMENT_TEAM = " + app["team"],
    "WAND_BUNDLE_Wand = " + app["bundleId"], "WAND_BUNDLE_WandWidgets = " + widget["bundleId"],
    "WAND_PROFILE_Wand = " + app["uuid"], "WAND_PROFILE_WandWidgets = " + widget["uuid"],
    "PRODUCT_BUNDLE_IDENTIFIER = $(WAND_BUNDLE_$(TARGET_NAME))",
    "PROVISIONING_PROFILE_SPECIFIER = $(WAND_PROFILE_$(TARGET_NAME))",
  ]
  (work / "Signing.xcconfig").write_text("\n".join(config) + "\n")
  options = {"method": "release-testing", "destination": "export", "signingStyle": "manual",
             "signingCertificate": identity, "teamID": app["team"], "thinning": "<none>",
             "manageAppVersionAndBuildNumber": False,
             "provisioningProfiles": {a["bundleId"]: a["uuid"] for a in facts}}
  (work / "ExportOptions.plist").write_bytes(plistlib.dumps(options))
  (work / "signing.json").write_text(json.dumps({"app": app, "widget": widget, "identity": identity}, indent=2) + "\n")
  print("Ad Hoc profiles and local distribution identity match the target device.")


def check_entitlements(actual, allowed):
  # Do not accept injected entitlements that the selected profile does not permit.
  def permitted(value, permission):
    if isinstance(value, str) and isinstance(permission, str):
      return value == permission or (permission.endswith("*") and value.startswith(permission[:-1]))
    if isinstance(value, list) and isinstance(permission, list):
      return all(any(permitted(item, option) for option in permission) for item in value)
    if isinstance(value, dict) and isinstance(permission, dict):
      return all(k in permission and permitted(v, permission[k]) for k, v in value.items())
    return type(value) is type(permission) and value == permission
  for key, value in actual.items():
    if key not in allowed or not permitted(value, allowed[key]):
      raise ValueError("Signed entitlement not permitted by profile: " + key)


def verify(args):
  expected = json.loads(pathlib.Path(args.work, "signing.json").read_text())
  ipa = pathlib.Path(args.ipa)
  # Keep extracted native artifacts on the configured build volume.
  with tempfile.TemporaryDirectory(prefix="verify-", dir=args.work) as tmp:
    root = pathlib.Path(tmp)
    with zipfile.ZipFile(ipa) as archive:
      for member in archive.infolist():
        path = pathlib.PurePosixPath(member.filename)
        mode = member.external_attr >> 16
        if path.is_absolute() or ".." in path.parts or stat.S_ISLNK(mode):
          raise ValueError("Unsafe or unsupported IPA entry")
      archive.extractall(root)
      for member in archive.infolist():
        mode = (member.external_attr >> 16) & 0o777
        if mode:
          (root / member.filename).chmod(mode)
    apps = list((root / "Payload").glob("*.app"))
    if len(apps) != 1:
      raise ValueError("Expected exactly one application")
    app = apps[0]
    extensions = list((app / "PlugIns").glob("*.appex"))
    if len(extensions) != 1:
      raise ValueError("Expected exactly one Widget extension")
    records = []
    for bundle, key in [(app, "app"), (extensions[0], "widget")]:
      fact = expected[key]
      # Codesign also checks all sealed nested code; never sign with --deep.
      run("codesign", "--verify", "--deep", "--strict", "--verbose=2", str(bundle))
      profile = decode_profile(bundle / "embedded.mobileprovision")
      checked = validate_profile(profile, args.udid)
      if any(checked[k] != fact[k] for k in ["bundleId", "team", "uuid", "applicationIdentifier"]):
        raise ValueError("Exported profile differs from the selected profile")
      info = plistlib.loads((bundle / "Info.plist").read_bytes())
      if info.get("CFBundleIdentifier") != fact["bundleId"] or info.get("CFBundleShortVersionString") != args.version:
        raise ValueError("Exported bundle identifier/version mismatch")
      if info.get("CFBundleVersion") != args.build_number:
        raise ValueError("Exported build number mismatch")
      ent = plistlib.loads(run("codesign", "-d", "--entitlements", ":-", str(bundle)))
      if ent.get("application-identifier") != fact["applicationIdentifier"] or ent.get("com.apple.developer.team-identifier") != fact["team"]:
        raise ValueError("Signed application/team identifier mismatch")
      if ent.get("get-task-allow", False):
        raise ValueError("Exported distribution app is debuggable")
      check_entitlements(ent, profile["Entitlements"])
      cert_dir = root / (key + "-certificates")
      cert_dir.mkdir()
      run("codesign", "-d", "--extract-certificates=" + str(cert_dir / "cert"), str(bundle))
      leaf = cert_dir / "cert0"
      if hashlib.sha1(leaf.read_bytes()).hexdigest().upper() != expected["identity"]:
        raise ValueError("Unexpected signing certificate")
      chain = sorted(cert_dir.glob("cert*"))
      command = ["security", "verify-cert", "-p", "codeSign"]
      for certificate in chain:
        command.extend(["-c", str(certificate)])
      run(*command)
      records.append({"target": key, "bundleId": fact["bundleId"], "team": fact["team"],
                      "profileExpires": str(profile["ExpirationDate"]), "signatureVerified": True,
                      "targetDeviceIncluded": True})
    digest = hashlib.sha256()
    with ipa.open("rb") as source:
      for chunk in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(chunk)
    result = {"version": args.version, "buildNumber": args.build_number,
              "fileName": ipa.name, "size": ipa.stat().st_size,
              "sha256": digest.hexdigest(), "bundles": records}
    pathlib.Path(args.work, "verified-ipa.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


def publish(args):
  work = pathlib.Path(args.work)
  receipt = json.loads((work / "verified-ipa.json").read_text())
  name = receipt["fileName"]
  if pathlib.Path(name).name != name or not name.endswith(".ipa"):
    raise ValueError("Invalid verified IPA filename")
  source = work / name
  if not receipt.get("bundles") or not all(b.get("signatureVerified") and b.get("targetDeviceIncluded") for b in receipt["bundles"]):
    raise ValueError("Full IPA verification must pass before publication")
  def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as file:
      for chunk in iter(lambda: file.read(1024 * 1024), b""):
        value.update(chunk)
    return value.hexdigest()
  if source.is_symlink() or source.stat().st_size != receipt["size"] or digest(source) != receipt["sha256"]:
    raise ValueError("IPA changed after signature verification")
  destination_dir = pathlib.Path(args.destination).resolve()
  config_path = pathlib.Path(args.config).resolve() if args.config else None
  previous = None
  if config_path:
    original = config_path.read_bytes()
    config = json.loads(original)
    ios = config.get("ios", {})
    configured_dir = pathlib.Path(ios.get("ipaDir") or "ios")
    if not configured_dir.is_absolute():
      configured_dir = config_path.parent / configured_dir
    if ios.get("enabled") is not True or configured_dir.resolve() != destination_dir:
      raise ValueError("Distribution directory differs from the enabled server iOS configuration")
    previous = ios.get("currentIpaFile", "")
    if previous and pathlib.Path(previous).name != previous:
      raise ValueError("Unexpected current IPA selector")
    old = destination_dir / previous if previous else None
    if old and old.is_file():
      with zipfile.ZipFile(old) as archive:
        entry = next(n for n in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n))
        info = plistlib.loads(archive.read(entry))
      if info.get("CFBundleIdentifier") == receipt["bundles"][0]["bundleId"]:
        old_build = tuple(int(n) for n in info["CFBundleVersion"].split("."))
        new_build = tuple(int(n) for n in receipt["buildNumber"].split("."))
        if new_build < old_build:
          raise ValueError("Refusing to replace a selected newer build")
    ios["currentIpaFile"] = name
    config["ios"] = ios
  destination_dir.mkdir(parents=True, exist_ok=True)
  destination = destination_dir / name
  if destination.exists():
    if destination.is_symlink() or digest(destination) != receipt["sha256"]:
      raise ValueError("Refusing to overwrite a different published IPA")
  else:
    fd, staging = tempfile.mkstemp(prefix=".adhoc-", dir=destination_dir)
    try:
      with os.fdopen(fd, "wb") as output, source.open("rb") as input:
        shutil.copyfileobj(input, output)
        output.flush(); os.fsync(output.fileno())
      if digest(pathlib.Path(staging)) != receipt["sha256"]:
        raise ValueError("Staged IPA digest mismatch")
      os.chmod(staging, 0o644)
      os.link(staging, destination)  # Atomic, no-clobber, preserves all previous packages.
    finally:
      os.unlink(staging)
  if config_path:
    fd, staging = tempfile.mkstemp(prefix=".ios-selection-", dir=config_path.parent)
    try:
      with os.fdopen(fd, "wb") as file:
        file.write((json.dumps(config, ensure_ascii=False, indent=2) + "\n").encode())
        file.flush(); os.fsync(file.fileno())
      os.chmod(staging, config_path.stat().st_mode & 0o777)
      if config_path.read_bytes() != original:
        raise ValueError("Concurrent server config write detected; signed IPA retained but selector unchanged")
      os.replace(staging, config_path)
    finally:
      if os.path.exists(staging): os.unlink(staging)
  result = {"fileName": name, "sha256": receipt["sha256"], "previousSelector": previous,
            "selected": config_path is not None, "deviceInstalled": False, "serverRestarted": False}
  (work / "published-ipa.json").write_text(json.dumps(result, indent=2) + "\n")
  print("Verified IPA published" + (" and selected by the existing server." if config_path else "."))


def main():
  parser = argparse.ArgumentParser(description=__doc__)
  sub = parser.add_subparsers(dest="command", required=True)
  pre = sub.add_parser("prepare")
  pre.add_argument("--app-profile", required=True)
  pre.add_argument("--widget-profile", required=True)
  for command in [pre, sub.add_parser("verify")]:
    command.add_argument("--work", required=True)
    command.add_argument("--udid", required=True)
  verify_parser = sub.choices["verify"]
  verify_parser.add_argument("--ipa", required=True)
  verify_parser.add_argument("--version", required=True)
  verify_parser.add_argument("--build-number", required=True)
  pub = sub.add_parser("publish")
  pub.add_argument("--work", required=True)
  pub.add_argument("--destination", required=True)
  pub.add_argument("--config")
  args = parser.parse_args()
  {"prepare": prepare, "verify": verify, "publish": publish}[args.command](args)


if __name__ == "__main__":
  main()
