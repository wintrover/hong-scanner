import 'package:flutter/material.dart';

import '../api/credentials.dart';

/// The one re-entry dialog for API credentials (Basic Auth).
///
/// Shown when the server answered 401 — whether or not a pair was stored
/// (stored-but-refused and never-entered both need fresh input). Submit
/// hands the pair to the caller, which persists it via the store's
/// saveCredentials and triggers the single retry; cancelling leaves the
/// visible 401 error states in place. Values are never logged.
Future<Credentials?> showCredentialPrompt(BuildContext context) {
  return showDialog<Credentials>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _CredentialDialog(),
  );
}

class _CredentialDialog extends StatefulWidget {
  const _CredentialDialog();

  @override
  State<_CredentialDialog> createState() => _CredentialDialogState();
}

class _CredentialDialogState extends State<_CredentialDialog> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _usernameController.text.isNotEmpty &&
      _passwordController.text.isNotEmpty;

  void _submit() {
    Navigator.of(context).pop(Credentials(
      username: _usernameController.text,
      password: _passwordController.text,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('API 인증 필요'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('이 서버는 Basic Auth로 보호됩니다. '
              '자격증명은 기기의 보안 저장소(Android Keystore)에만 저장되고 '
              '기록·전송·로그에 남지 않습니다.'),
          const SizedBox(height: 12),
          TextField(
            controller: _usernameController,
            autofillHints: const [AutofillHints.username],
            decoration: const InputDecoration(
              labelText: '사용자명',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _refreshSubmitState(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            obscureText: true,
            autofillHints: const [AutofillHints.password],
            decoration: const InputDecoration(
              labelText: '비밀번호',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) {
              if (_canSubmit) _submit();
            },
            onChanged: (_) => _refreshSubmitState(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        TextButton(
          onPressed: _canSubmit ? _submit : null,
          child: const Text('저장하고 재시도'),
        ),
      ],
    );
  }

  void _refreshSubmitState() => setState(() {});
}
