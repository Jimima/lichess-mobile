import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/utils/async_value.dart';

import 'package:lichess_mobile/src/utils/l10n_context.dart';
import 'package:lichess_mobile/src/widgets/feedback.dart';
import 'package:lichess_mobile/src/model/settings/providers.dart';
import 'package:lichess_mobile/src/model/auth/auth_controller.dart';

class SignInWidget extends ConsumerWidget {
  const SignInWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authController = ref.watch(authControllerProvider);
    final brightness = ref.watch(currentBrightnessProvider);
    ref.listen<AsyncValue<void>>(
      authControllerProvider,
      (_, state) => state.showSnackbarOnError(context),
    );

    final button = TextButton(
      onPressed: () => ref.read(authControllerProvider.notifier).signIn(),
      child: Text(
        context.l10n.signIn,
        style: defaultTargetPlatform == TargetPlatform.android &&
                brightness == Brightness.light
            ? const TextStyle(color: Colors.white)
            : null,
      ),
    );
    return authController.when(
      data: (session) => session == null ? button : const SizedBox.shrink(),
      error: (err, st) {
        debugPrint(
          'SEVERE: [SignInWidget] error: $err\n$st',
        );
        return button;
      },
      loading: () => const ButtonLoadingIndicator(),
    );
  }
}