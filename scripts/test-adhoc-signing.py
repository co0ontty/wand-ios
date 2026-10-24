#!/usr/bin/env python3
"""Offline validation tests; never access the keychain, portal, or devices."""
import datetime
import hashlib
import importlib.util
import json
import pathlib
import sys
import tempfile
import types
import zipfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("adhoc_signing", pathlib.Path(__file__).with_name("adhoc-signing.py"))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
NOW = datetime.datetime(2026, 10, 16, 13)
UDID = "test-device"
TEAM = "ABCDE12345"


def profile(bundle="com.example.wand"):
  return {"CreationDate": NOW - datetime.timedelta(days=1),
          "ExpirationDate": NOW + datetime.timedelta(days=100),
          "UUID": "a409cc4e-2e6d-46cf-8ca1-edce52b9a9ee", "TeamIdentifier": [TEAM],
          "ApplicationIdentifierPrefix": [TEAM], "Platform": ["iOS"],
          "ProvisionedDevices": [UDID], "DeveloperCertificates": [b"test certificate"],
          "Entitlements": {"application-identifier": TEAM + "." + bundle,
                           "com.apple.developer.team-identifier": TEAM, "get-task-allow": False}}


class SigningTests(unittest.TestCase):
  def fact(self, value=None):
    return signing.validate_profile(value if value is not None else profile(), UDID, NOW)

  def test_valid_explicit_profile(self):
    self.assertEqual(self.fact()["bundleId"], "com.example.wand")

  def test_expired_and_future_profiles_fail(self):
    for key, value in [("ExpirationDate", NOW), ("CreationDate", NOW + datetime.timedelta(seconds=1))]:
      with self.subTest(key=key):
        p = profile(); p[key] = value
        with self.assertRaises(ValueError): self.fact(p)

  def test_unregistered_device_fails(self):
    p = profile(); p["ProvisionedDevices"] = ["another-device"]
    with self.assertRaises(ValueError): self.fact(p)

  def test_app_store_enterprise_and_development_fail(self):
    variants = []
    p = profile(); p.pop("ProvisionedDevices"); variants.append(p)
    p = profile(); p["ProvisionsAllDevices"] = True; variants.append(p)
    p = profile(); p["Entitlements"]["get-task-allow"] = True; variants.append(p)
    for p in variants:
      with self.subTest(profile=p):
        with self.assertRaises(ValueError): self.fact(p)

  def test_wildcard_and_xcconfig_injection_fail(self):
    for bundle in ["com.example.*", "com.example.app\nCODE_SIGNING_ALLOWED = NO", "com.example.app//x"]:
      with self.subTest(bundle=bundle):
        with self.assertRaises(ValueError): self.fact(profile(bundle))

  def test_universal_apple_profile_includes_ios(self):
    p = profile(); p["Platform"] = ["iOS", "xrOS", "visionOS"]
    self.assertEqual(self.fact(p)["bundleId"], "com.example.wand")

  def test_missing_certificate_and_wrong_platform_fail(self):
    for key, value in [("DeveloperCertificates", []), ("Platform", ["tvOS"]), ("UUID", "invalid")]:
      p = profile(); p[key] = value
      with self.subTest(key=key):
        with self.assertRaises(ValueError): self.fact(p)

  def test_team_entitlement_mismatch_fails(self):
    p = profile(); p["Entitlements"]["com.apple.developer.team-identifier"] = "OTHER12345"
    with self.assertRaises(ValueError): self.fact(p)

  def test_main_apns_environment_is_required_but_widget_need_not_enable_push(self):
    app = self.fact()
    with self.assertRaises(ValueError): signing.require_apns_environment(app)
    for value in ["development", "", None]:
      with self.subTest(value=value):
        with self.assertRaises(ValueError): signing.require_apns_environment({**app, "apnsEnvironment": value})
    p = profile(); p["Entitlements"]["aps-environment"] = "production"
    self.assertEqual(signing.require_apns_environment(self.fact(p)), "production")
    signing.validate_pair(self.fact(p), self.fact(profile("com.example.wand.widgets")))

  def test_matching_app_widget(self):
    signing.validate_pair(self.fact(), self.fact(profile("com.example.wand.widgets")))

  def test_mismatched_team_widget_prefix_and_certificate_fail(self):
    app = self.fact()
    for field, value in [("team", "OTHER12345"), ("bundleId", "com.other.widgets"), ("certificates", ["other"])]:
      widget = self.fact(profile("com.example.wand.widgets")); widget[field] = value
      with self.subTest(field=field):
        with self.assertRaises(ValueError): signing.validate_pair(app, widget)

  def test_entitlements_subset_and_terminal_wildcards(self):
    allowed = {"keychain-access-groups": [TEAM + ".*"], "get-task-allow": False}
    signing.check_entitlements({"keychain-access-groups": [TEAM + ".com.example.app"], "get-task-allow": False}, allowed)
    for actual in [{"get-task-allow": True}, {"new-capability": True}, {"keychain-access-groups": ["OTHER.app"]}]:
      with self.subTest(actual=actual):
        with self.assertRaises(ValueError): signing.check_entitlements(actual, allowed)
    self.assertEqual(allowed["get-task-allow"], False)


class PublicationTests(unittest.TestCase):
  def setUp(self):
    self.tmp = tempfile.TemporaryDirectory()
    self.root = pathlib.Path(self.tmp.name).resolve()
    self.work = self.root / "work"; self.work.mkdir()
    self.destination = self.root / "ios"
    self.name = "wand-v4.96.0-debug.10162130.ipa"
    self.source = self.work / self.name
    self.source.write_bytes(b"verified signed package fixture")
    self.receipt = {"fileName": self.name, "size": self.source.stat().st_size,
                    "sha256": hashlib.sha256(self.source.read_bytes()).hexdigest(), "buildNumber": "49600.10162130",
                    "bundles": [{"bundleId": "com.example.wand", "signatureVerified": True, "targetDeviceIncluded": True}]}
    (self.work / "verified-ipa.json").write_text(json.dumps(self.receipt))
    self.config = self.root / "config.json"
    self.original = {"ios": {"enabled": True, "ipaDir": "ios", "currentIpaFile": ""}, "unrelated": {"value": 42}}
    self.config.write_text(json.dumps(self.original))
    self.args = types.SimpleNamespace(work=str(self.work), destination=str(self.destination), config=str(self.config))

  def tearDown(self):
    self.tmp.cleanup()

  def test_publication_selects_verified_package_preserves_unrelated_config_and_is_idempotent(self):
    signing.publish(self.args)
    selected = json.loads(self.config.read_text())
    self.assertEqual(selected["ios"]["currentIpaFile"], self.name)
    self.assertEqual(selected["unrelated"], self.original["unrelated"])
    self.assertEqual((self.destination / self.name).read_bytes(), self.source.read_bytes())
    # No second copy or replacement of an existing, identical signed artifact.
    self.args.config = None
    signing.publish(self.args)
    self.assertEqual(len(list(self.destination.glob("*.ipa"))), 1)

  def test_tampered_package_never_publishes_or_changes_selector(self):
    self.source.write_bytes(b"changed after verification")
    with self.assertRaises(ValueError): signing.publish(self.args)
    self.assertEqual(json.loads(self.config.read_text()), self.original)
    self.assertFalse(self.destination.exists())

  def test_wrong_destination_never_changes_configuration(self):
    self.args.destination = str(self.root / "other")
    with self.assertRaises(ValueError): signing.publish(self.args)
    self.assertEqual(json.loads(self.config.read_text()), self.original)

  def test_different_existing_package_is_not_overwritten(self):
    self.destination.mkdir(); old = self.destination / self.name; old.write_bytes(b"old package")
    with self.assertRaises(ValueError): signing.publish(self.args)
    self.assertEqual(old.read_bytes(), b"old package")
    self.assertEqual(json.loads(self.config.read_text()), self.original)

  def test_disabled_distribution_never_publishes(self):
    config = {**self.original, "ios": {**self.original["ios"], "enabled": False}}
    self.config.write_text(json.dumps(config))
    with self.assertRaises(ValueError): signing.publish(self.args)
    self.assertFalse(self.destination.exists())

  def test_unverified_receipt_is_rejected(self):
    self.receipt["bundles"][0]["signatureVerified"] = False
    (self.work / "verified-ipa.json").write_text(json.dumps(self.receipt))
    with self.assertRaises(ValueError): signing.publish(self.args)
    self.assertFalse(self.destination.exists())

  def test_selected_newer_build_cannot_be_downgraded(self):
    self.destination.mkdir()
    old = self.destination / "newer.ipa"
    import plistlib
    with zipfile.ZipFile(old, "w") as archive:
      archive.writestr("Payload/Wand.app/Info.plist", plistlib.dumps({
        "CFBundleIdentifier": "com.example.wand", "CFBundleVersion": "49600.10162131"}))
    config = {**self.original, "ios": {**self.original["ios"], "currentIpaFile": old.name}}
    self.config.write_text(json.dumps(config))
    with self.assertRaisesRegex(ValueError, "newer"):
      signing.publish(self.args)
    self.assertFalse((self.destination / self.name).exists())
    self.assertEqual(json.loads(self.config.read_text()), config)

  def test_concurrent_configuration_write_preserves_the_newer_writer(self):
    real_read = pathlib.Path.read_bytes
    reads = 0
    newer = {**self.original, "concurrent": True}
    def read(path):
      nonlocal reads
      if path == self.config:
        reads += 1
        if reads == 2: self.config.write_text(json.dumps(newer))
      return real_read(path)
    with patch.object(pathlib.Path, "read_bytes", read):
      with self.assertRaisesRegex(ValueError, "Concurrent"):
        signing.publish(self.args)
    self.assertEqual(json.loads(self.config.read_text()), newer)
    self.assertTrue((self.destination / self.name).exists())


if __name__ == "__main__":
  unittest.main()
