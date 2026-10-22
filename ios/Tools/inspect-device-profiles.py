#!/usr/bin/env python3
"""只读验证App与Widget专用推送所需开发profiles；两者必须aps-environment=development。旧无aps的Widget profile不再适用。不安装/签名/联网/创建凭据。"""
import argparse, datetime, fnmatch, hashlib, json, pathlib, plistlib, subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('app_profile', type=pathlib.Path)
p.add_argument('widget_profile', type=pathlib.Path)
p.add_argument('--udid', required=True)
p.add_argument('--team', required=True, help='Apple Developer team ID for your installation')
p.add_argument('--identity', required=True, help='已有有效Apple Development身份SHA1')
a = p.parse_args()
team = a.team
group = 'group.dev.matianyi.agentinbox'
results = []
for role, path, bundle in [('app', a.app_profile, 'dev.matianyi.agentinbox'), ('widget', a.widget_profile, 'dev.matianyi.agentinbox.widget')]:
    profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(path.resolve())], stderr=subprocess.DEVNULL))
    ent = profile['Entitlements']
    prefix = profile['ApplicationIdentifierPrefix'][0]
    expected_keychain = prefix + '.dev.matianyi.agentinbox.shared'
    checks = {
        'team': profile.get('TeamIdentifier') == [team],
        'exactApplicationId': ent.get('application-identifier') == prefix + '.' + bundle,
        'developmentDebug': ent.get('get-task-allow') is True,
        'registeredPhysicalDevice': a.udid in profile.get('ProvisionedDevices', []),
        'appGroup': group in ent.get('com.apple.security.application-groups', []),
        'sharedKeychain': any(fnmatch.fnmatchcase(expected_keychain, item) for item in ent.get('keychain-access-groups', [])),
        'existingCertificate': a.identity.upper() in [hashlib.sha1(cert).hexdigest().upper() for cert in profile.get('DeveloperCertificates', [])],
        'notExpired': profile['ExpirationDate'].replace(tzinfo=datetime.timezone.utc) > datetime.datetime.now(datetime.timezone.utc),
        'pushEnvironment': ent.get('aps-environment') == 'development',
    }
    results.append({'role': role, 'file': str(path.resolve()), 'bundleId': bundle, 'uuid': profile['UUID'], 'name': profile['Name'], 'applicationIdentifierPrefix': prefix, 'sharedKeychainGroup': expected_keychain, 'checks': checks, 'valid': all(checks.values())})
assert results[0]['applicationIdentifierPrefix'] == results[1]['applicationIdentifierPrefix'], 'App与Widget签名prefix不一致，拒绝共享'
print(json.dumps({'manualProfiles': results, 'allValid': all(r['valid'] for r in results), 'createsCertificateOrKey': False, 'installsProfiles': False}, ensure_ascii=False, indent=2))
raise SystemExit(0 if all(r['valid'] for r in results) else 1)
