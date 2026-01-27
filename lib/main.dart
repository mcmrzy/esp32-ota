import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'ota_protocol.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();

  static _MyAppState of(BuildContext context) => context.findAncestorStateOfType<_MyAppState>()!;
}

class _MyAppState extends State<MyApp> {
  ThemeMode _themeMode = ThemeMode.light;

  void toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ESP32 OTA Uploader',
      themeMode: _themeMode,
      theme: ThemeData(
        brightness: Brightness.light,
        colorScheme: ColorScheme.light(
          primary: const Color(0xFF1976D2),
          secondary: const Color(0xFF388E3C),
          surface: Colors.white,
          background: const Color(0xFFF5F5F5),
          onSurface: Colors.black,
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
        cardColor: Colors.white,
        useMaterial3: true,
        fontFamily: 'Segoe UI',
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFF64B5F6),
          secondary: const Color(0xFF81C784),
          surface: const Color(0xFF1E1E1E),
          background: const Color(0xFF121212),
          onSurface: Colors.white,
        ),
        scaffoldBackgroundColor: const Color(0xFF121212),
        cardColor: const Color(0xFF1E1E1E),
        useMaterial3: true,
        fontFamily: 'Segoe UI',
      ),
      home: const MyHomePage(title: 'ESP32 OTA Tool'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with SingleTickerProviderStateMixin {
  List<String> _ports = [];
  String? _selectedPort;
  final TextEditingController _baudController = TextEditingController(text: '2000000');
  String? _filePath;
  double _progress = 0.0;
  bool _isUploading = false;
  bool _isDragging = false;
  final ScrollController _logScrollController = ScrollController();
  final List<String> _logs = [];

  ESP32OTA? _ota;
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _refreshPorts();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    _baudController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  void _refreshPorts() {
    setState(() {
      try {
        _ports = SerialPort.availablePorts.toSet().toList();
      } catch (e) {
        _ports = [];
        _addLog("[-] 获取串口失败: $e");
      }
      
      if (_selectedPort != null && !_ports.contains(_selectedPort)) {
        _selectedPort = null;
      }
      
      if (_selectedPort == null && _ports.isNotEmpty) {
        _selectedPort = _ports.first;
      }
    });
  }

  void _addLog(String msg) {
    setState(() {
      _logs.add(msg);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['bin'],
    );

    if (result != null) {
      setState(() {
        _filePath = result.files.single.path;
      });
    }
  }

  Future<void> _startOTA() async {
    if (_selectedPort == null) {
      _addLog("[-] 请选择串口");
      return;
    }
    if (_filePath == null) {
      _addLog("[-] 请选择固件文件");
      return;
    }

    final baud = int.tryParse(_baudController.text);
    if (baud == null) {
      _addLog("[-] 无效的波特率");
      return;
    }

    setState(() {
      _isUploading = true;
      _progress = 0.0;
      _logs.clear();
      _animationController.repeat();
    });

    _ota = ESP32OTA(_selectedPort!, baud, log: _addLog);

    try {
      if (await _ota!.connect()) {
        if (await _ota!.sync()) {
          await Future.delayed(const Duration(milliseconds: 500));
          
          bool success = await _ota!.uploadFile(_filePath!, (p) {
            setState(() {
              _progress = p;
            });
          });

          if (success) {
            _addLog("[+] 全部完成");
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('固件升级成功！'), backgroundColor: Colors.green),
            );
          } else {
            _addLog("[-] 上传失败");
             ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('固件升级失败'), backgroundColor: Colors.red),
            );
          }
        } else {
          _addLog("[-] 同步失败");
        }
      } 
    } catch (e) {
      _addLog("[-] 异常: $e");
    } finally {
      _ota?.disconnect();
      setState(() {
        _isUploading = false;
        _animationController.stop();
        _animationController.reset();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        surfaceTintColor: Theme.of(context).colorScheme.surface,
        elevation: 0,
        title: Text(widget.title, style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface)),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
            onPressed: () {
              MyApp.of(context).toggleTheme();
            },
            tooltip: isDark ? "切换到亮色模式" : "切换到深色模式",
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            // Settings Card
            Card(
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(Icons.settings_input_component, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            value: _selectedPort,
                            dropdownColor: Theme.of(context).cardColor,
                            decoration: InputDecoration(
                              labelText: '串口 (Port)',
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            ),
                            items: _ports.map((String value) {
                              return DropdownMenuItem<String>(
                                value: value,
                                child: Text(value),
                              );
                            }).toList(),
                            onChanged: _isUploading ? null : (v) => setState(() => _selectedPort = v),
                          ),
                        ),
                        const SizedBox(width: 12),
                        IconButton(
                          icon: const Icon(Icons.refresh),
                          onPressed: _isUploading ? null : _refreshPorts,
                          tooltip: "刷新串口",
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 150,
                          child: TextField(
                            controller: _baudController,
                            decoration: InputDecoration(
                              labelText: '波特率 (Baud)',
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            ),
                            keyboardType: TextInputType.number,
                            enabled: !_isUploading,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // File Drop Zone
            DropTarget(
              onDragDone: (detail) {
                if (_isUploading) return;
                if (detail.files.isNotEmpty) {
                  final file = detail.files.first;
                  if (file.path.toLowerCase().endsWith('.bin')) {
                    setState(() {
                      _filePath = file.path;
                    });
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('请选择 .bin 文件')),
                    );
                  }
                }
              },
              onDragEntered: (_) => setState(() => _isDragging = true),
              onDragExited: (_) => setState(() => _isDragging = false),
              child: InkWell(
                onTap: _isUploading ? null : _pickFile,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  height: 150,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: _isDragging 
                      ? Theme.of(context).colorScheme.primary.withOpacity(0.1) 
                      : Theme.of(context).cardColor,
                    border: Border.all(
                      color: _isDragging 
                          ? Theme.of(context).colorScheme.primary 
                          : Colors.grey.withOpacity(0.5),
                        width: 2,
                        style: BorderStyle.solid
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.cloud_upload_outlined, 
                        size: 48, 
                        color: _filePath != null ? Colors.green : Colors.grey
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _filePath != null 
                            ? "已选择: ${_filePath!.split(RegExp(r'[/\\]')).last}" 
                            : "点击或拖拽固件文件 (.bin) 到此处",
                        style: TextStyle(
                          fontSize: 16, 
                          color: _filePath != null ? Colors.green : Colors.grey,
                          fontWeight: _filePath != null ? FontWeight.bold : FontWeight.normal
                        ),
                      ),
                      if (_filePath != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Text(
                            _filePath!, 
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        )
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Start Button
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: _isUploading ? null : _startOTA,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: _isUploading ? 0 : 4,
                ),
                child: _isUploading 
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 24, 
                          height: 24, 
                          child: CircularProgressIndicator(
                            color: Colors.white, 
                            strokeWidth: 2.5,
                          )
                        ),
                        const SizedBox(width: 16),
                        const Text("正在升级中...", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      ],
                    )
                  : const Text("开始升级 (Start Flash)", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
            ),
            
            const SizedBox(height: 24),
            
            // Progress Bar
            if (_isUploading) ...[
               TweenAnimationBuilder<double>(
                 tween: Tween<double>(begin: 0, end: _progress),
                 duration: const Duration(milliseconds: 200),
                 builder: (context, value, _) => LinearProgressIndicator(
                   value: value, 
                   minHeight: 12,
                   borderRadius: BorderRadius.circular(6),
                   backgroundColor: isDark ? Colors.grey[800] : Colors.grey[300],
                   valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.secondary),
                 ),
               ),
               const SizedBox(height: 8),
               Align(
                 alignment: Alignment.centerRight,
                 child: Text(
                   "${(_progress * 100).toStringAsFixed(1)}%",
                   style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                 ),
               ),
               const SizedBox(height: 16),
            ],

            // Logs
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.withOpacity(0.2)),
                ),
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Terminal Output >_", 
                      style: TextStyle(
                        color: isDark ? Colors.grey : Colors.grey[700], 
                        fontFamily: 'Consolas', 
                        fontWeight: FontWeight.bold
                      )
                    ),
                    const Divider(color: Colors.grey, height: 20, thickness: 0.5),
                    Expanded(
                      child: ListView.builder(
                        controller: _logScrollController,
                        itemCount: _logs.length,
                        itemBuilder: (context, index) {
                          final log = _logs[index];
                          // Adapt colors for light/dark mode
                          Color color;
                          if (log.contains("[-]")) {
                            color = isDark ? Colors.redAccent : Colors.red[700]!;
                          } else if (log.contains("[!]")) {
                            color = isDark ? Colors.orangeAccent : Colors.orange[800]!;
                          } else if (log.contains("[*]")) {
                            color = isDark ? Colors.lightBlueAccent : Colors.blue[700]!;
                          } else {
                            color = isDark ? Colors.greenAccent : Colors.green[700]!;
                          }
                          
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2.0),
                            child: Text(
                              log,
                              style: TextStyle(
                                color: color,
                                fontFamily: 'Consolas',
                                fontSize: 13,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
