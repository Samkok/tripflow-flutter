import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/theme.dart';
import '../providers/theme_provider.dart';
import '../screens/terms_screen.dart';

class ProfileMenuButton extends ConsumerWidget {
  const ProfileMenuButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeProvider);
    
    return PopupMenuButton<int>(
      onSelected: (item) {
        if (item == 1) {
          ref.read(themeProvider.notifier).toggleTheme();
        } else if (item == 3) {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (context) => const TermsScreen()),
          );
        }
        // Handle other items if needed
      },
      color: Theme.of(context).cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      itemBuilder: (context) => [
        // User Profile Header
        PopupMenuItem<int>(
          enabled: false, // Not selectable
          value: -1,
          child: Row(
            children: [
              const CircleAvatar(
                backgroundColor: AppTheme.primaryColor, // Keeping primary for avatar
                child: Text('U', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Anonymous User', style: Theme.of(context).textTheme.titleMedium),
                  Text('user@voyza.com', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        // Theme Switch
        PopupMenuItem<int>(
          value: 1,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    themeMode == ThemeMode.dark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  const Text('Theme'),
                ],
              ),
              Text(
                themeMode == ThemeMode.dark ? 'Dark' : 'Light',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        // More Settings
        // PopupMenuItem<int>(
        //   value: 2,
        //   child: Row(
        //     children: [
        //       Icon(Icons.settings_outlined, color: Theme.of(context).textTheme.bodyMedium?.color),
        //       SizedBox(width: 12),
        //       Text('More Settings'),
        //     ],
        //   ),
        // ),
        // Terms and Conditions
        PopupMenuItem<int>(
          value: 3,
          child: Row(
            children: [
              Icon(Icons.description_outlined, color: Theme.of(context).textTheme.bodyMedium?.color),
              const SizedBox(width: 12),
              const Text('Terms & Conditions'),
            ],
          ),
        ),
      ],
      child: const CircleAvatar(
        backgroundColor: AppTheme.primaryColor, // Keeping primary for avatar
        child: Icon(Icons.person, color: Colors.black),
      ),
    );
  }
}