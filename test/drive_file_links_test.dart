import 'package:cloudspace_app/services/drive/drive_account.dart';
import 'package:cloudspace_app/services/drive/drive_client.dart';
import 'package:cloudspace_app/services/drive/drive_file_links.dart';
import 'package:flutter_test/flutter_test.dart';

DriveAccount acct(String id, String server) => DriveAccount(
    id: id, serverUrl: server, token: 'dk_$id', userId: 'u$id', tenantId: 't', email: '$id@x', displayName: id, isAdmin: false);

const fid = '3f2b8c1e-0a4d-4e6f-9b1a-2c3d4e5f6a7b';

void main() {
  test('only Drive file links are recognised', () {
    expect(fileIdFromLink(Uri.parse('https://drive.worldposta.com/file/$fid')), fid);
    expect(fileIdFromLink(Uri.parse('https://drive.worldposta.com/file/${fid.toUpperCase()}/')), fid);
    expect(fileIdFromLink(Uri.parse('https://drive.worldposta.com/file/not-an-id')), isNull);
    expect(fileIdFromLink(Uri.parse('https://drive.worldposta.com/drive/my')), isNull);
    expect(fileIdFromLink(Uri.parse('https://drive.worldposta.com/file/$fid/edit')), isNull);
    expect(fileIdFromLink(Uri.parse('postadrive://google?status=picked')), isNull);
  });

  test('push keeps only file links', () {
    final l = DriveFileLinks.instance;
    l.take();
    l.push(Uri.parse('https://drive.worldposta.com/login'));
    expect(l.pending, isNull);
    l.push(Uri.parse('https://drive.worldposta.com/file/$fid'));
    expect(l.take()?.path, '/file/$fid');
    expect(l.pending, isNull);
  });

  group('which account opens the link', () {
    final a = acct('a', 'https://drive.worldposta.com');
    final b = acct('b', 'https://drive.worldposta.com/');
    final other = acct('o', 'https://drive.example.com');

    test('active account first', () async {
      final tried = <String>[];
      final t = await findAccountForFile(
          linkHost: 'drive.worldposta.com', accounts: [a, b], activeId: 'b',
          probe: (x) async => tried.add(x.id));
      expect(t.outcome, FileLinkOutcome.open);
      expect(t.accountId, 'b');
      expect(tried, ['b']);
    });

    test('falls back to another account on the same Drive, skipping other servers', () async {
      final tried = <String>[];
      final t = await findAccountForFile(
          linkHost: 'drive.worldposta.com', accounts: [other, a, b], activeId: 'a',
          probe: (x) async {
            tried.add(x.id);
            if (x.id == 'a') throw DriveException('permission_denied', 'no', 403);
          });
      expect(t.accountId, 'b');
      expect(tried, ['a', 'b']);
    });

    test('no account can see it', () async {
      final t = await findAccountForFile(
          linkHost: 'drive.worldposta.com', accounts: [a, other], activeId: 'a',
          probe: (x) async => throw DriveException('not_found', 'gone', 404));
      expect(t.outcome, FileLinkOutcome.noAccess);
    });

    test('a link to a Drive you are not signed in to is no access', () async {
      final t = await findAccountForFile(
          linkHost: 'drive.worldposta.com', accounts: [other], activeId: 'o', probe: (_) async {});
      expect(t.outcome, FileLinkOutcome.noAccess);
    });

    test('network trouble is reported, not called no access', () async {
      final t = await findAccountForFile(
          linkHost: 'drive.worldposta.com', accounts: [a, b], activeId: 'a',
          probe: (x) async => throw DriveException('network', 'offline', 0));
      expect(t.outcome, FileLinkOutcome.failed);
    });
  });
}
