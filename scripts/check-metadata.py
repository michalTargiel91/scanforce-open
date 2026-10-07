"""Offline metadata, least-privilege and distribution guardrails. No org or credentials needed."""
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path("force-app/main/default")
NS = {"m": "http://soap.sforce.com/2006/04/metadata"}
JOB = "SfdcDcx_Processing_Job__c"
INTERNAL_FIELDS = {"Dedup_Hash__c", "Submission_Key__c"}
HEADER_FORMULA = "{!'Bearer ' & $Credential.SfdcDcx_ProviderAuth.Token}"
ALLOWED_DIRS = {
    "applications", "classes", "customPermissions", "flexipages", "layouts",
    "lwc", "objects", "permissionsets", "tabs",
}
FORBIDDEN_DIRS = {
    "connectedApps", "externalClientApps", "remoteSiteSettings", "customMetadata",
    "staticresources", "namedCredentials", "externalCredentials", "settings",
}
# The retired ScanForce package, its backend and its OAuth registration never return.
# (Apex may only contain the https://docsolved.ai/connect preset URL; see check_apex.)
LEGACY_MARKERS = (
    "scanforce__", "ScanForcePackage", "tokens__mdt", "RegisterOrgService",
    "ConnectedApp", "refresh_token", "/v1/register", "/v1/revoke",
)
APEX_BANNED = ("ContentDistribution", "getSessionId(", "base64Encode(", "System.debug(")
TEST_SUPPORT = ("Test", "TestFactory")


def text(element, path):
    return element.findtext(path, namespaces=NS)


def is_test(file):
    return file.stem.endswith(TEST_SUPPORT)


def check_project():
    project = json.loads(Path("sfdx-project.json").read_text())
    assert project["namespace"] == ""
    assert [p["path"] for p in project["packageDirectories"]] == ["force-app"]
    assert project["packageDirectories"][0]["default"] is True
    assert project["sourceApiVersion"] == "67.0"
    names = {p.name for p in ROOT.iterdir()}
    assert names <= ALLOWED_DIRS, names - ALLOWED_DIRS
    assert not names & FORBIDDEN_DIRS, names & FORBIDDEN_DIRS
    for file in ROOT.rglob("*.xml"):
        for element in ET.parse(file).iter():
            if element.tag.endswith("apiVersion"):
                assert element.text == project["sourceApiVersion"], file


def check_apex():
    classes = {p.stem for p in (ROOT / "classes").glob("*.cls")}
    objects = {p.name for p in (ROOT / "objects").iterdir()}
    share_objects = {name.replace("__c", "__Share") for name in objects}
    known = classes | objects | share_objects | {
        "SfdcDcx_Use", "SfdcDcx_Admin", "SfdcDcx_Provider", "SfdcDcx_ProviderAuth",
        "SfdcDcx_Connector_User", "SfdcDcx_Provider_Access", "SfdcDcx_Test_Provider_Access",
    }
    for file in (ROOT / "classes").glob("*.cls"):
        assert file.name.startswith("SfdcDcx_"), file
        assert Path(str(file) + "-meta.xml").is_file(), file
        content = file.read_text()
        if not is_test(file):
            assert re.search(r"\b(without|with|inherited) sharing class\b", content) or " interface " in content, file
        for banned in APEX_BANNED:
            assert banned not in content, (file, banned)
        for marker in LEGACY_MARKERS:
            assert marker.lower() not in content.lower(), (file, marker)
        for reference in re.findall(r"\bSfdcDcx_[A-Za-z_][A-Za-z_0-9]*", content):
            assert reference in known, (file, reference)
        if is_test(file):
            continue
        # The only network destination is the administrator-owned Named Credential.
        for url in re.findall(r"https?://[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+[^'\\s]*", content):
            assert url.startswith(("https://docsolved.ai/connect", "https://provider.example.com/")), (file, url)
        if "new Http()" in content:
            assert file.stem in ("SfdcDcx_HttpProviderGateway", "SfdcDcx_ProviderConnection"), file
        if re.search(r"SELECT[^\]']*VersionData", content):
            assert file.stem == "SfdcDcx_ContentVersionSelector", file
    return classes


def field_names(object_name):
    return {p.name.split(".")[0] for p in (ROOT / "objects" / object_name / "fields").glob("*.xml")}


def check_objects():
    fields = field_names(JOB)
    for file in (ROOT / "objects" / JOB / "fields").glob("*.xml"):
        assert text(ET.parse(file), "m:fullName") == file.name.split(".")[0], file
    obj = ET.parse(ROOT / "objects" / JOB / f"{JOB}.object-meta.xml")
    assert text(obj, "m:sharingModel") == "Private"
    rule = ET.parse(ROOT / "objects" / JOB / "validationRules/Source_Association_Immutable.validationRule-meta.xml")
    assert text(rule, "m:active") == "true"
    mapping = field_names("SfdcDcx_Field_Mapping__mdt")
    assert mapping == {"Document_Type__c", "Target_Object__c", "Result_Path__c", "Target_Field__c", "Active__c"}
    settings = field_names("SfdcDcx_Settings__c")
    assert settings == {"Provider_Origin__c"}, "Custom settings hold non-secret values only"
    for file in (ROOT / "classes").glob("*.cls"):
        if is_test(file):
            continue  # tests reference deliberately unknown fields
        for name in re.findall(r"\b[A-Za-z][A-Za-z_0-9]*__c\b", file.read_text()):
            assert name in fields | mapping | settings | {JOB, "SfdcDcx_Settings__c"}, (file, name)
    return fields


def check_permission_set(name, fields, classes, tabs, view_all):
    tree = ET.parse(ROOT / "permissionsets" / f"{name}.permissionset-meta.xml")
    granted = set()
    for permission in tree.findall("m:fieldPermissions", NS):
        assert text(permission, "m:editable") == "false", (name, "editable field")
        object_name, field = text(permission, "m:field").split(".")
        assert object_name == JOB and field in fields, (name, field)
        granted.add(field)
    for permission in tree.findall("m:objectPermissions", NS):
        assert text(permission, "m:object") == JOB
        assert text(permission, "m:allowRead") == "true"
        for flag in ("allowCreate", "allowDelete", "allowEdit", "modifyAllRecords"):
            assert text(permission, f"m:{flag}") == "false", (name, flag)
        assert text(permission, "m:viewAllRecords") == ("true" if view_all else "false"), (name, "viewAll")
    granted_classes = {text(c, "m:apexClass") for c in tree.findall("m:classAccesses", NS)}
    assert granted_classes <= classes, granted_classes - classes
    for permission in tree.findall("m:customPermissions/m:name", NS):
        assert (ROOT / "customPermissions" / f"{permission.text}.customPermission-meta.xml").is_file()
    for tab in tree.findall("m:tabSettings/m:tab", NS):
        assert tab.text in tabs, (name, tab.text)
    for app in tree.findall("m:applicationVisibilities/m:application", NS):
        assert (ROOT / "applications" / f"{app.text}.app-meta.xml").is_file()
    return granted, granted_classes


def check_permissions(fields, classes):
    tabs = {p.name.split(".")[0] for p in (ROOT / "tabs").glob("*.xml")}
    user_fields, user_classes = check_permission_set("SfdcDcx_Connector_User", fields, classes, tabs, False)
    admin_fields, admin_classes = check_permission_set("SfdcDcx_Admin", fields, classes, tabs, True)
    assert user_fields == fields - INTERNAL_FIELDS, "Users read every user-facing field and no idempotency digest"
    assert admin_fields == fields
    assert "SfdcDcx_SetupController" in admin_classes and "SfdcDcx_SetupController" not in user_classes
    assert user_classes <= admin_classes
    entry_points = {
        p.stem for p in (ROOT / "classes").glob("*.cls")
        if not is_test(p) and ("@AuraEnabled\n  public static" in p.read_text() or "@InvocableMethod" in p.read_text())
    }
    assert entry_points <= admin_classes, entry_points - admin_classes


def check_lwc():
    for bundle in (ROOT / "lwc").iterdir():
        if not bundle.is_dir():
            continue
        meta = bundle / f"{bundle.name}.js-meta.xml"
        assert bundle.name.startswith("sfdcDcx") and meta.is_file(), bundle
        assert text(ET.parse(meta), "m:apiVersion") == "67.0", meta
        for source in bundle.glob("*.js"):
            content = source.read_text()
            for banned in ("innerHTML", "eval(", "document.cookie", "localStorage", "http://"):
                assert banned not in content, (source, banned)


def check_credentials_bootstrap():
    """provider-config is deployed once and never carries a secret or a real endpoint."""
    nc = ET.parse("provider-config/namedCredentials/SfdcDcx_Provider.namedCredential-meta.xml")
    urls = [text(p, "m:parameterValue") for p in nc.findall("m:namedCredentialParameters", NS)
            if text(p, "m:parameterType") == "Url"]
    assert urls == ["https://example.invalid/connect"], urls
    assert text(nc, "m:generateAuthorizationHeader") == "false"
    ec_path = Path("provider-config/externalCredentials/SfdcDcx_ProviderAuth.externalCredential-meta.xml")
    kinds = {text(p, "m:parameterType") for p in ET.parse(ec_path).findall("m:externalCredentialParameters", NS)}
    assert kinds == {"NamedPrincipal", "AuthHeader"}, kinds
    assert "{!'Bearer ' &amp; $Credential.SfdcDcx_ProviderAuth.Token}" in ec_path.read_text()
    configuration = Path("docs/configuration.md").read_text()
    for reference in ("SfdcDcx_Provider", "SfdcDcx_ProviderAuth", "External Credential Principal Access", HEADER_FORMULA):
        assert reference in configuration, reference


check_project()
apex_classes = check_apex()
job_fields = check_objects()
check_permissions(job_fields, apex_classes)
check_lwc()
check_credentials_bootstrap()
print("Metadata, prefix, least-privilege, credential-bootstrap and distribution guardrails passed.")
