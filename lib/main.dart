import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ---------------------------------------------------------------------------
// 极简 i18n：中文 / 英文两张表，运行时切换并持久化。
// ---------------------------------------------------------------------------
class L {
  static bool en = false;
  static String t(String zh, String enText) => en ? enText : zh;
}

class S {
  static String get title => L.t('RCPU 手机挖矿', 'RCPU Mobile Miner');
  static String get wallet => L.t('钱包地址', 'Wallet address');
  static String get walletHint =>
      L.t('你的 rcpu1… 地址，不要用 rcpux1…', 'Your rcpu1… address, never rcpux1…');
  static String get pool => L.t('矿池地址', 'Pool address');
  static String get poolHint =>
      L.t('stratum+tcp://主机:端口', 'stratum+tcp://host:port');
  static String get threads => L.t('线程数', 'Threads');
  static String get start => L.t('开始挖矿', 'Start mining');
  static String get stop => L.t('停止', 'Stop');
  static String get running => L.t('挖矿中', 'Mining');
  static String get stopped => L.t('已停止', 'Stopped');
  static String get status => L.t('状态', 'Status');
  static String get cores => L.t('核心', 'cores');
  static String get hashrate => L.t('实时算力', 'Hashrate');
  static String get shares => L.t('股份', 'Shares');
  static String get uptime => L.t('运行时长', 'Uptime');
  static String get logs => L.t('运行日志', 'Log');
  static String get language => L.t('语言', 'Language');
  static String get clear => L.t('清空', 'Clear');
  static String get walletRequired =>
      L.t('请先填写钱包地址', 'Wallet address is required');
  static String get walletConfidential => L.t(
      '不能用 rcpux1 机密地址挖矿，请填 rcpu1',
      'rcpux1 confidential addresses cannot mine, use rcpu1');
  static String get poolInvalid => L.t('矿池地址格式不对，应为 stratum+tcp://主机:端口',
      'Pool must look like stratum+tcp://host:port');
  static String get startFailed => L.t('启动失败', 'Failed to start');
  static String get exited => L.t('矿机进程已退出', 'Miner process exited');
  static String get batteryHint => L.t(
      '手机上跑 RandomX 算力有限（约 100–500 H/s），会发热耗电，建议插电使用。',
      'RandomX on a phone is slow (about 100–500 H/s) and drains the battery — keep it plugged in.');
  static String get noLogs => L.t('还没有日志', 'No log yet');
}

// ---------------------------------------------------------------------------
// 设置持久化：写到应用目录的 json，不依赖任何插件。
// ---------------------------------------------------------------------------
class Settings {
  String wallet = '';
  String pool = 'stratum+tcp://207.57.129.188:3334';
  int threads = 4;
  bool en = false;

  static File? _file;

  static Future<void> init() async {
    try {
      // Android 上 HOME 常为空，目录名从可写位置里挑第一个成功的。
      final candidates = <String>[
        if ((Platform.environment['HOME'] ?? '').isNotEmpty)
          Platform.environment['HOME']!,
        if ((Platform.environment['TMPDIR'] ?? '').isNotEmpty)
          Platform.environment['TMPDIR']!,
        Directory.systemTemp.path,
      ];
      for (final base in candidates) {
        try {
          final dir = Directory('$base/rcpu_miner');
          if (!await dir.exists()) await dir.create(recursive: true);
          final probe = File('${dir.path}/.ok');
          await probe.writeAsString('1');
          _file = File('${dir.path}/settings.json');
          return;
        } catch (_) {
          continue;
        }
      }
    } catch (_) {}
  }

  static Future<Settings> load() async {
    final s = Settings();
    try {
      if (_file != null && await _file!.exists()) {
        final m = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        s.wallet = (m['wallet'] ?? '') as String;
        s.pool = (m['pool'] ?? s.pool) as String;
        s.threads = (m['threads'] as num?)?.toInt() ?? s.threads;
        s.en = (m['en'] as bool?) ?? false;
      }
    } catch (_) {}
    return s;
  }

  Future<void> save() async {
    try {
      await _file?.writeAsString(jsonEncode({
        'wallet': wallet,
        'pool': pool,
        'threads': threads,
        'en': en,
      }));
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// 主界面
// ---------------------------------------------------------------------------
void main() {
  runApp(const MinerApp());
}

class MinerApp extends StatelessWidget {
  const MinerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RCPU Miner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFFC9A227),
        scaffoldBackgroundColor: const Color(0xFF0D1117),
      ),
      home: const MinerPage(),
    );
  }
}

class MinerPage extends StatefulWidget {
  const MinerPage({super.key});
  @override
  State<MinerPage> createState() => _MinerPageState();
}

class _MinerPageState extends State<MinerPage> {
  static const _channel = MethodChannel('rcpu/miner');

  final Settings _settings = Settings();
  final _walletCtrl = TextEditingController();
  final _poolCtrl = TextEditingController();
  final _logCtrl = ScrollController();

  Process? _proc;
  StreamSubscription<String>? _sub;
  final List<String> _logs = <String>[];
  /// 手机逻辑核心数，线程上限就取它
  final int _cores = Platform.numberOfProcessors;
  String? _nativeDir;
  String _dirSource = '';
  String _appVersion = '';

  bool _running = false;
  double _hashrate = 0;
  int _accepted = 0;
  int _rejected = 0;
  DateTime? _startedAt;
  String? _error;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await Settings.init();
    final loaded = await Settings.load();
    _nativeDir = await _resolveNativeDir();
    try {
      _appVersion = await _channel.invokeMethod<String>('appVersion') ?? '';
    } catch (_) {
      _appVersion = '';
    }
    if (!mounted) return;
    setState(() {
      _settings.wallet = loaded.wallet;
      _settings.pool = loaded.pool;
      _settings.threads = loaded.threads.clamp(1, _cores);
      _settings.en = loaded.en;
      L.en = loaded.en;
      _walletCtrl.text = loaded.wallet;
      _poolCtrl.text = loaded.pool;
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_running && mounted) setState(() {});
    });
  }

  /// 找原生库目录。优先问原生层，失败则从 /proc/self/maps 里
  /// 反查 libflutter.so 的位置——比自己拼路径可靠。
  Future<String?> _resolveNativeDir() async {
    try {
      final dir = await _channel.invokeMethod<String>('nativeLibDir');
      if (dir != null && dir.isNotEmpty) {
        _dirSource = 'channel';
        return dir;
      }
    } catch (e) {
      _dirSource = 'channel failed: $e';
    }
    final fromMaps = await _dirFromMaps();
    if (fromMaps != null) {
      _dirSource = 'maps: $fromMaps';
      return fromMaps;
    }
    _dirSource = 'not found';
    return null;
  }

  Future<String?> _dirFromMaps() async {
    try {
      final maps = await File('/proc/self/maps').readAsString();
      for (final line in maps.split('\n')) {
        if (line.contains('libflutter.so') || line.contains('libapp.so')) {
          final parts = line.trim().split(RegExp(r'\s+'));
          final path = parts.isEmpty ? '' : parts.last;
          if (path.startsWith('/')) {
            return path.substring(0, path.lastIndexOf('/'));
          }
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  void dispose() {
    _stopMiner();
    _ticker?.cancel();
    _walletCtrl.dispose();
    _poolCtrl.dispose();
    _logCtrl.dispose();
    super.dispose();
  }

  Future<String> _binaryPath() async {
    final candidates = <String>[];
    if (_nativeDir != null && _nativeDir!.isNotEmpty) {
      candidates.add('$_nativeDir/libminerdrcpu.so');
    }
    candidates.add('libminerdrcpu.so');
    for (final c in candidates) {
      try {
        if (c == 'libminerdrcpu.so' || await File(c).exists()) return c;
      } catch (_) {}
    }
    return candidates.last;
  }

  void _append(String line) {
    final clean = line.trimRight();
    if (clean.isEmpty) return;
    _logs.add(clean);
    if (_logs.length > 400) _logs.removeAt(0);
    _parse(clean);
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logCtrl.hasClients) {
        _logCtrl.animateTo(_logCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 120), curve: Curves.easeOut);
      }
    });
  }

  // cpuminer 的真实输出格式：
  //   [ts] thread 0: 1270 hashes, 0.22 khash/s
  //   [ts] accepted: 5/5 (100.00%), 1.20 khash/s yes!
  static final _reAccepted = RegExp(
      r"accepted:\s*(\d+)/(\d+)\s*\([^)]*\)\s*,\s*([\d.]+)\s*([kKmMgG]?)hash/s");
  static final _reThread =
      RegExp(r"thread\s+(\d+):.*?([\d.]+)\s*([kKmMgG]?)hash/s");
  final Map<int, double> _threadRates = <int, double>{};

  static double _mult(String u) {
    switch (u.toLowerCase()) {
      case 'k':
        return 1e3;
      case 'm':
        return 1e6;
      case 'g':
        return 1e9;
      default:
        return 1;
    }
  }

  void _parse(String line) {
    // 汇总行：同时给出股份与总算力，优先采用
    final a = _reAccepted.firstMatch(line);
    if (a != null) {
      final acc = int.tryParse(a.group(1)!) ?? _accepted;
      final total = int.tryParse(a.group(2)!) ?? acc;
      _accepted = acc;
      _rejected = total > acc ? total - acc : 0;
      final rate = double.tryParse(a.group(3)!) ?? 0;
      _hashrate = rate * _mult(a.group(4)!);
      return;
    }
    // 单线程行：按线程号累加，作为汇总行之间的实时值
    final t = _reThread.firstMatch(line);
    if (t != null) {
      final idx = int.tryParse(t.group(1)!) ?? 0;
      final rate = double.tryParse(t.group(2)!) ?? 0;
      _threadRates[idx] = rate * _mult(t.group(3)!);
      _hashrate = _threadRates.values.fold<double>(0, (x, y) => x + y);
    }
  }

  String get _hashrateText {
    if (_hashrate >= 1e6) return '${(_hashrate / 1e6).toStringAsFixed(2)} MH/s';
    if (_hashrate >= 1e3) return '${(_hashrate / 1e3).toStringAsFixed(2)} kH/s';
    return '${_hashrate.toStringAsFixed(0)} H/s';
  }

  String get _uptimeText {
    if (_startedAt == null) return '--';
    final d = DateTime.now().difference(_startedAt!);
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m ${s}s';
  }

  Future<void> _startMiner() async {
    final wallet = _walletCtrl.text.trim();
    final pool = _poolCtrl.text.trim();
    setState(() => _error = null);

    if (wallet.isEmpty) {
      setState(() => _error = S.walletRequired);
      return;
    }
    if (wallet.startsWith('rcpux1')) {
      setState(() => _error = S.walletConfidential);
      return;
    }
    if (!pool.startsWith('stratum+tcp://')) {
      setState(() => _error = S.poolInvalid);
      return;
    }

    _settings.wallet = wallet;
    _settings.pool = pool;
    await _settings.save();

    final args = <String>[
      '-a',
      'randomx',
      '-o',
      pool,
      '-u',
      wallet,
      '-p',
      'x',
      '-t',
      '${_settings.threads}',
    ];

    try {
      final bin = await _binaryPath();
      // 把定位结果先写进日志，方便排查路径问题。
      _logs.add('native dir: ${_nativeDir ?? "(none)"} [$_dirSource]');
      final libDir = (bin.contains('/'))
          ? bin.substring(0, bin.lastIndexOf('/'))
          : '.';
      final p = await Process.start(bin, args, environment: {
        // 矿机动态链接 libcurl / libjansson / libc++_shared，
        // 它们和可执行文件放在同一个原生库目录里。
        'LD_LIBRARY_PATH': '$libDir:/system/lib64:/vendor/lib64',
      });
      _proc = p;
      _startedAt = DateTime.now();
      _hashrate = 0;
      _accepted = 0;
      _rejected = 0;
      _logs.add('> $bin ${args.join(' ')}');
      setState(() => _running = true);

      _sub = p.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_append);
      p.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_append);
      unawaited(p.exitCode.then((code) {
        if (!mounted) return;
        setState(() {
          _running = false;
          if (_error == null) _error = '${S.exited} (code $code)';
        });
        _proc = null;
      }));
    } catch (e) {
      setState(() {
        _running = false;
        _error = '${S.startFailed}: $e';
      });
    }
  }

  Future<void> _stopMiner() async {
    await _sub?.cancel();
    _sub = null;
    _proc?.kill(ProcessSignal.sigterm);
    _proc = null;
    if (mounted) {
      setState(() {
        _running = false;
        _hashrate = 0;
        _threadRates.clear();
      });
    }
  }

  void _toggleLang() {
    setState(() {
      _settings.en = !_settings.en;
      L.en = _settings.en;
    });
    _settings.save();
  }

  Widget _statCard(String label, String value, {Color? color}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1F27),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF2A3038)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(fontSize: 12, color: Color(0xFF8B949E))),
            const SizedBox(height: 6),
            Text(value,
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: color ?? const Color(0xFFF0F6FC))),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width > 600;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('RCPU', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(width: 8),
            Text(S.title,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w400)),
            if (_appVersion.isNotEmpty) ...[
              const SizedBox(width: 6),
              Text('v$_appVersion',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF8B949E))),
            ],
          ],
        ),
        actions: [
          IconButton(
            tooltip: S.language,
            onPressed: _toggleLang,
            icon: Text(L.en ? '中' : 'EN',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            _statCard(S.hashrate, _hashrateText),
            const SizedBox(width: 10),
            _statCard(S.shares, '$_accepted ok / $_rejected rej'),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            _statCard(
              S.status,
              _running ? S.running : S.stopped,
              color: _running ? const Color(0xFF3FB950) : const Color(0xFF8B949E),
            ),
            const SizedBox(width: 10),
            _statCard(S.uptime, _uptimeText),
          ]),
          const SizedBox(height: 16),
          TextField(
            controller: _walletCtrl,
            enabled: !_running,
            decoration: InputDecoration(
              labelText: S.wallet,
              helperText: S.walletHint,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.account_balance_wallet_outlined),
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _poolCtrl,
            enabled: !_running,
            decoration: InputDecoration(
              labelText: S.pool,
              helperText: S.poolHint,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.dns_outlined),
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(S.threads, style: const TextStyle(color: Color(0xFF8B949E))),
              const SizedBox(width: 12),
              Expanded(
                child: Slider(
                  value: _settings.threads.clamp(1, _cores).toDouble(),
                  min: 1,
                  max: _cores.toDouble(),
                  divisions: _cores > 1 ? _cores - 1 : 1,
                  label: '${_settings.threads}',
                  onChanged: _running
                      ? null
                      : (v) => setState(() => _settings.threads = v.round()),
                  onChangeEnd: (_) => _settings.save(),
                ),
              ),
              Text('${_settings.threads} / $_cores',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 50,
            child: FilledButton.icon(
              onPressed: _running ? _stopMiner : _startMiner,
              icon: Icon(_running ? Icons.stop : Icons.play_arrow),
              label: Text(_running ? S.stop : S.start),
              style: FilledButton.styleFrom(
                backgroundColor:
                    _running ? const Color(0xFFDA3633) : const Color(0xFF238636),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: Color(0xFFFF7B72))),
          ],
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF2A3038)),
            ),
            child: Text(S.batteryHint,
                style: const TextStyle(fontSize: 12, color: Color(0xFF8B949E))),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text(S.logs, style: const TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() => _logs.clear()),
                child: Text(S.clear, style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
          Container(
            height: wide ? 280 : 220,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF0B0F14),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF2A3038)),
            ),
            child: _logs.isEmpty
                ? Center(
                    child: Text(S.noLogs,
                        style: const TextStyle(
                            color: Color(0xFF484F58), fontSize: 12)))
                : ListView.builder(
                    controller: _logCtrl,
                    itemCount: _logs.length,
                    itemBuilder: (_, i) => Text(
                      _logs[i],
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        height: 1.4,
                        color: Color(0xFFC9D1D9),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
