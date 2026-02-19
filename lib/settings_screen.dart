import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'settings_manager.dart';
import 'audio_engine.dart';
import 'l10n.dart';
import 'main.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = SettingsManager();
  final _audio = AudioEngine();
  final _l10n = L10n();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(_l10n.tr('settings'))),
      body: ListView(
        children: [
          // ─── 音量 ───────────────────────────────────────────
          _sectionTitle(_l10n.tr('volume')),
          _sliderTile(
            title: _l10n.tr('volume'),
            icon: Icons.volume_up,
            value: _settings.globalVolume,
            min: 0.0, max: 2.0, divisions: 40,
            format: (v) => '${(v * 100).round()}%',
            onChanged: (v) {
              setState(() => _settings.globalVolume = v);
              _audio.setGlobalVolume(v);
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(_l10n.tr('audio_dist_tip'),
                style: TextStyle(
                  color: colorScheme.outline,
                  fontSize: 12,
                  fontFamily: 'NotoSansJP',
                )),
          ),
          _sliderTile(
            title: _l10n.tr('gain'),
            icon: Icons.mic,
            value: _settings.micGain,
            min: 0.1, max: 5.0, divisions: 49,
            format: (v) => 'x${v.toStringAsFixed(1)}',
            onChanged: (v) => setState(() => _settings.micGain = v),
          ),
          _sliderTile(
            title: '${_l10n.tr('tune')} ${_l10n.tr('volume')}',
            icon: Icons.audiotrack,
            value: _settings.refVolume,
            min: 0.0, max: 1.0, divisions: 20,
            format: (v) => '${(v * 100).round()}%',
            onChanged: (v) => setState(() => _settings.refVolume = v),
          ),
          const Divider(),
          // ─── チューナー ────────────────────────────────────
          _sectionTitle(_l10n.tr('tune')),
          _intStepTile(
            title: _l10n.tr('a4_freq'),
            subtitle: '${_settings.a4Ref} Hz',
            value: _settings.a4Ref,
            min: 410, max: 480,
            onChanged: (v) {
              setState(() => _settings.a4Ref = v);
              InfKeyApp.of(context).rebuild();
            },
          ),
          const Divider(),
          // ─── ピアノ ─────────────────────────────────────────
          _sectionTitle(_l10n.tr('play')),
          _intStepTile(
            title: _l10n.tr('transpose'),
            subtitle: '${_settings.transpose >= 0 ? '+' : ''}${_settings.transpose} 半音',
            value: _settings.transpose,
            min: -12, max: 12,
            onChanged: (v) {
              setState(() => _settings.transpose = v);
              InfKeyApp.of(context).rebuild();
            },
          ),
          _intStepTile(
            title: _l10n.tr('tuning'),
            subtitle: '${_settings.tuning >= 0 ? '+' : ''}${_settings.tuning} cent',
            value: _settings.tuning,
            min: -100, max: 100,
            onChanged: (v) {
              setState(() => _settings.tuning = v);
              InfKeyApp.of(context).rebuild();
            },
          ),
          const Divider(),
          // ─── メトロノーム タイミング ──────────────────────
          _sectionTitle(_l10n.tr('metro_timing')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(_l10n.tr('timing_note'),
                style: TextStyle(
                  color: colorScheme.outline,
                  fontSize: 12,
                  fontFamily: 'NotoSansJP',
                )),
          ),
          _intSliderTile(
            title: _l10n.tr('timing_sound'),
            icon: Icons.volume_up,
            value: _settings.soundOffsetMs,
            min: -20, max: 50,
            format: (v) => '${v >= 0 ? '+' : ''}$v ms',
            onChanged: (v) => setState(() => _settings.soundOffsetMs = v),
          ),
          _intSliderTile(
            title: _l10n.tr('timing_haptic'),
            icon: Icons.vibration,
            value: _settings.hapticOffsetMs,
            min: -20, max: 50,
            format: (v) => '${v >= 0 ? '+' : ''}$v ms',
            onChanged: (v) => setState(() => _settings.hapticOffsetMs = v),
          ),
          _intSliderTile(
            title: _l10n.tr('timing_vibration'),
            icon: Icons.sensors,
            value: _settings.vibrationOffsetMs,
            min: -20, max: 50,
            format: (v) => '${v >= 0 ? '+' : ''}$v ms',
            onChanged: (v) => setState(() => _settings.vibrationOffsetMs = v),
          ),
          _intSliderTile(
            title: _l10n.tr('timing_flash'),
            icon: Icons.flash_on,
            value: _settings.flashOffsetMs,
            min: -20, max: 50,
            format: (v) => '${v >= 0 ? '+' : ''}$v ms',
            onChanged: (v) => setState(() => _settings.flashOffsetMs = v),
          ),
          const Divider(),
          // ─── テーマ ─────────────────────────────────────────
          _sectionTitle(_l10n.tr('theme')),
          ListTile(
            leading: const Icon(Icons.palette),
            title: Text(_l10n.tr('theme')),
            trailing: DropdownButton<int>(
              value: _settings.themeMode,
              items: [
                DropdownMenuItem(value: 0, child: Text(_l10n.tr('system'))),
                DropdownMenuItem(value: 1, child: Text(_l10n.tr('light'))),
                DropdownMenuItem(value: 2, child: Text(_l10n.tr('dark'))),
              ],
              onChanged: (v) {
                if (v != null) {
                  setState(() => _settings.themeMode = v);
                  InfKeyApp.of(context).rebuild();
                }
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.colorize),
            title: Text(_l10n.tr('theme_color')),
            trailing: DropdownButton<int>(
              value: _settings.colorSeed,
              items: [
                DropdownMenuItem(value: 0, child: Text(_l10n.tr('color_dynamic'))),
                DropdownMenuItem(value: 1, child: Text(_l10n.tr('color_blue'))),
                DropdownMenuItem(value: 2, child: Text(_l10n.tr('color_green'))),
                DropdownMenuItem(value: 3, child: Text(_l10n.tr('color_red'))),
                DropdownMenuItem(value: 4, child: Text(_l10n.tr('color_purple'))),
                DropdownMenuItem(value: 5, child: Text(_l10n.tr('color_orange'))),
              ],
              onChanged: (v) {
                if (v != null) {
                  setState(() => _settings.colorSeed = v);
                  InfKeyApp.of(context).rebuild();
                }
              },
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.brightness_2),
            title: Text(_l10n.tr('oled_black')),
            value: _settings.isOled,
            onChanged: (v) {
              setState(() => _settings.isOled = v);
              InfKeyApp.of(context).rebuild();
            },
          ),
          const Divider(),
          // ─── 言語 ────────────────────────────────────────────
          _sectionTitle(_l10n.tr('language')),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(_l10n.tr('language')),
            trailing: DropdownButton<String>(
              value: _settings.language,
              items: [
                DropdownMenuItem(value: 'auto', child: Text(_l10n.tr('auto'))),
                DropdownMenuItem(value: 'ja', child: Text(_l10n.tr('japanese'))),
                DropdownMenuItem(value: 'en', child: Text(_l10n.tr('english'))),
              ],
              onChanged: (v) {
                if (v != null) {
                  setState(() => _settings.language = v);
                  _l10n.locale = v == 'auto' ? 'ja' : v;
                  InfKeyApp.of(context).rebuild();
                }
              },
            ),
          ),
          const Divider(),
          _sectionTitle('info'),
          const ListTile(
            title: Text('Version'),
            trailing: Text('1.2.0'),
          ),
        ],
      ),
    );
  }

  // ─── セクションタイトル ──────────────────────────────────
  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(title,
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.bold,
            fontSize: 14,
            fontFamily: 'NotoSansJP',
          )),
    );
  }

  // ─── スライダータイル（double / タップして直接入力） ──────
  Widget _sliderTile({
    required String title,
    required IconData icon,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String Function(double) format,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: Icon(icon),
          title: Text(title),
          trailing: GestureDetector(
            onTap: () => _showDoubleInputDialog(title, value, min, max, onChanged),
            child: Text(format(value),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.underline,
                )),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Slider(
            value: value.clamp(min, max),
            min: min, max: max, divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  // ─── 整数スライダータイル（タップして直接入力） ──────────
  Widget _intSliderTile({
    required String title,
    required IconData icon,
    required int value,
    required int min,
    required int max,
    required String Function(int) format,
    required ValueChanged<int> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: Icon(icon),
          title: Text(title),
          trailing: GestureDetector(
            onTap: () => _showIntInputDialog(title, value, min, max, onChanged),
            child: Text(format(value),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.underline,
                )),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Slider(
            value: value.toDouble(),
            min: min.toDouble(), max: max.toDouble(),
            divisions: max - min,
            onChanged: (v) => onChanged(v.round()),
          ),
        ),
      ],
    );
  }

  // ─── +/- ボタン + タップ直接入力タイル ───────────────────
  Widget _intStepTile({
    required String title,
    required String subtitle,
    required int value,
    required int min,
    required int max,
    required ValueChanged<int> onChanged,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove),
            onPressed: value > min ? () => onChanged((value - 1).clamp(min, max)) : null,
          ),
          GestureDetector(
            onTap: () => _showIntInputDialog(title, value, min, max, onChanged),
            child: Text('$value',
                style: TextStyle(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  decoration: TextDecoration.underline,
                )),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: value < max ? () => onChanged((value + 1).clamp(min, max)) : null,
          ),
        ],
      ),
    );
  }

  // ─── ダイアログ: double 直接入力 ───────────────────────────
  Future<void> _showDoubleInputDialog(
    String label, double current, double min, double max,
    ValueChanged<double> onChanged,
  ) async {
    final ctrl = TextEditingController(text: current.toStringAsFixed(2));
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          autofocus: true,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]'))],
          decoration: InputDecoration(hintText: '$min ~ $max'),
          onSubmitted: (s) {
            final v = double.tryParse(s);
            if (v != null) onChanged(v.clamp(min, max));
            Navigator.of(ctx).pop();
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(_l10n.tr('cancel'))),
          TextButton(
            onPressed: () {
              final v = double.tryParse(ctrl.text);
              if (v != null) onChanged(v.clamp(min, max));
              Navigator.of(ctx).pop();
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // ─── ダイアログ: int 直接入力 ──────────────────────────────
  Future<void> _showIntInputDialog(
    String label, int current, int min, int max,
    ValueChanged<int> onChanged,
  ) async {
    final ctrl = TextEditingController(text: '$current');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(signed: true),
          autofocus: true,
          decoration: InputDecoration(hintText: '$min ~ $max'),
          onSubmitted: (s) {
            final v = int.tryParse(s);
            if (v != null) onChanged(v.clamp(min, max));
            Navigator.of(ctx).pop();
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(_l10n.tr('cancel'))),
          TextButton(
            onPressed: () {
              final v = int.tryParse(ctrl.text);
              if (v != null) onChanged(v.clamp(min, max));
              Navigator.of(ctx).pop();
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
