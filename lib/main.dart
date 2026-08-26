import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'app/theme.dart';
import 'features/session/home_page.dart';
import 'features/session/session_cubit.dart';
import 'services/workspace.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Workspace.purgeOrphans();

  runApp(const CrispApp());
}

class CrispApp extends StatelessWidget {
  const CrispApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Crisp',
      debugShowCheckedModeBanner: false,
      theme: CrispTheme.build(),
      home: BlocProvider(
        create: (_) => SessionCubit(),
        child: const HomePage(),
      ),
    );
  }
}
