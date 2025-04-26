import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _requestPermissions();
  runApp(const BLEFileReceiverApp());
}

Future<void> _requestPermissions() async {
  await [
    Permission.bluetooth,
    Permission.bluetoothConnect,
    Permission.bluetoothScan,
    Permission.storage,
    if (Platform.isAndroid) Permission.locationWhenInUse,
  ].request();
}

class BLEFileReceiverApp extends StatelessWidget {
  const BLEFileReceiverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'مستقبل الملفات عبر البلوتوث',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const DeviceScanScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class DeviceScanScreen extends StatefulWidget {
  const DeviceScanScreen({super.key});

  @override
  State<DeviceScanScreen> createState() => _DeviceScanScreenState();
}

class _DeviceScanScreenState extends State<DeviceScanScreen> {
  final List<BluetoothDevice> _devices = [];
  bool _isScanning = false;
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  @override
  void dispose() {
    _scanSubscription?.cancel();
    super.dispose();
  }

  Future<void> _startScan() async {
    try {
      setState(() => _isScanning = true);
      _devices.clear();

      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        _updateDeviceList(results);
      }, onError: (e) => _showError('خطأ في البحث: ${e.toString()}'));

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
        androidUsesFineLocation: true,
      );
    } catch (e) {
      _showError('فشل في بدء البحث: ${e.toString()}');
    }
  }

  void _updateDeviceList(List<ScanResult> results) {
    final newDevices = results
        .where((r) => r.device.name.isNotEmpty)
        .map((r) => r.device)
        .toSet()
        .toList();

    setState(() => _devices
      ..clear()
      ..addAll(newDevices));
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
    setState(() => _isScanning = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('الأجهزة المتاحة'),
        actions: [
          IconButton(
            icon: Icon(_isScanning ? Icons.stop : Icons.search),
            onPressed: _isScanning ? FlutterBluePlus.stopScan : _startScan,
          )
        ],
      ),
      body: _devices.isEmpty
          ? const Center(child: Text('لم يتم العثور على أجهزة'))
          : ListView.builder(
              itemCount: _devices.length,
              itemBuilder: (ctx, i) => ListTile(
                leading: const Icon(Icons.bluetooth),
                title: Text(_devices[i].name),
                subtitle: Text(_devices[i].remoteId.toString()),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => FileTransferScreen(device: _devices[i]),
                  ),
                ),
              ),
            ),
    );
  }
}

class FileTransferScreen extends StatefulWidget {
  final BluetoothDevice device;

  const FileTransferScreen({super.key, required this.device});

  @override
  State<FileTransferScreen> createState() => _FileTransferScreenState();
}

class _FileTransferScreenState extends State<FileTransferScreen> {
  final _serviceUuid = Guid("0000ffe0-0000-1000-8000-00805f9b34fb");
  final _charUuid = Guid("0000ffe1-0000-1000-8000-00805f9b34fb");
  
  List<int> _receivedData = [];
  bool _isReceiving = false;
  String _status = 'جاري الاتصال...';
  StreamSubscription<List<int>>? _dataSubscription;

  @override
  void initState() {
    super.initState();
    _connectToDevice();
  }

  @override
  void dispose() {
    _dataSubscription?.cancel();
    widget.device.disconnect();
    super.dispose();
  }

  Future<void> _connectToDevice() async {
    try {
      await widget.device.connect(autoConnect: false);
      final services = await widget.device.discoverServices();
      
      final targetService = services.firstWhere(
        (s) => s.uuid == _serviceUuid,
        orElse: () => throw Exception('الخدمة غير موجودة'),
      );

      final characteristic = targetService.characteristics.firstWhere(
        (c) => c.uuid == _charUuid,
        orElse: () => throw Exception('الخاصية غير موجودة'),
      );

      await characteristic.setNotifyValue(true);
      _dataSubscription = characteristic.value.listen(_handleData);

      setState(() => _status = 'متصل - جاهز لاستقبال الملفات');
    } catch (e) {
      setState(() => _status = 'فشل الاتصال: ${e.toString().split(':').first}');
    }
  }

  void _handleData(List<int> data) {
    if (!_isReceiving && data.first == 0x02) {
      _startReceiving();
    }

    if (_isReceiving) {
      setState(() => _receivedData.addAll(data));
    }

    if (data.last == 0x03) {
      _finishReceiving();
    }
  }

  void _startReceiving() {
    setState(() {
      _isReceiving = true;
      _receivedData = [];
      _status = 'جاري استقبال البيانات...';
    });
  }

  Future<void> _finishReceiving() async {
    try {
      final dir = await getDownloadsDirectory();
      final file = File('${dir?.path}/ملف_مستقبل_${DateTime.now().millisecondsSinceEpoch}.pdf');
      await file.writeAsBytes(Uint8List.fromList(_receivedData));
      
      setState(() {
        _isReceiving = false;
        _status = 'تم الحفظ: ${file.path.split('/').last}';
      });
    } catch (e) {
      setState(() => _status = 'فشل الحفظ: ${e.toString()}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.name),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.bluetooth_connected,
                  color: _status.contains('متصل') ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 10),
                Text(_status, style: const TextStyle(fontSize: 18)),
              ],
            ),
            const SizedBox(height: 20),
            if (_isReceiving) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 10),
              Text('تم استقبال ${_receivedData.length} بايت'),
            ],
          ],
        ),
      ),
    );
  }
}
