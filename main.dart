import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initializeApp();
  runApp(const BLEFileReceiverApp());
}

Future<void> _initializeApp() async {
  await Permission.bluetooth.request();
  await Permission.bluetoothConnect.request();
  await Permission.bluetoothScan.request();
  await Permission.storage.request();
  if (Platform.isAndroid) {
    await Permission.locationWhenInUse.request();
  }
}

class BLEFileReceiverApp extends StatelessWidget {
  const BLEFileReceiverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE File Receiver',
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
      }, onError: (e) => _showError('Scan Error: ${e.toString()}'));

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
        androidUsesFineLocation: true,
      );
    } catch (e) {
      _showError('Scan Failed: ${e.toString()}');
    }
  }

  void _updateDeviceList(List<ScanResult> results) {
    final newDevices = results
        .where((r) => r.device.name.isNotEmpty)
        .map((r) => r.device)
        .toSet()
        .toList();

    setState(() {
      _devices
        ..clear()
        ..addAll(newDevices);
    });
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
    setState(() => _isScanning = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Available Devices'),
        actions: [
          IconButton(
            icon: Icon(_isScanning ? Icons.stop : Icons.search),
            onPressed: _isScanning ? FlutterBluePlus.stopScan : _startScan,
          )
        ],
      ),
      body: _devices.isEmpty
          ? const Center(child: Text('No devices found'))
          : ListView.builder(
              itemCount: _devices.length,
              itemBuilder: (ctx, i) => DeviceTile(
                device: _devices[i],
                onConnect: (device) => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => FileTransferScreen(device: device),
                  ),
                ),
              ),
            ),
    );
  }
}

class DeviceTile extends StatelessWidget {
  final BluetoothDevice device;
  final Function(BluetoothDevice) onConnect;

  const DeviceTile({
    super.key,
    required this.device,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.bluetooth),
      title: Text(device.name),
      subtitle: Text(device.remoteId.toString()),
      trailing: IconButton(
        icon: const Icon(Icons.link),
        onPressed: () => onConnect(device),
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
  String _status = 'Connecting...';
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
        orElse: () => throw Exception('Service not found'),
      );

      final characteristic = targetService.characteristics.firstWhere(
        (c) => c.uuid == _charUuid,
        orElse: () => throw Exception('Characteristic not found'),
      );

      await characteristic.setNotifyValue(true);
      _dataSubscription = characteristic.value.listen(_handleData);

      setState(() => _status = 'Connected - Ready to receive');
    } catch (e) {
      setState(() => _status = 'Connection Failed: ${e.toString()}');
    }
  }

  void _handleData(List<int> data) {
    if (!_isReceiving && data.first == 0x02) { // STX Start of text
      _startReceiving();
    }

    if (_isReceiving) {
      setState(() => _receivedData.addAll(data));
    }

    if (data.last == 0x03) { // ETX End of text
      _finishReceiving();
    }
  }

  void _startReceiving() {
    setState(() {
      _isReceiving = true;
      _receivedData = [];
      _status = 'Receiving data...';
    });
  }

  Future<void> _finishReceiving() async {
    try {
      final dir = await getDownloadsDirectory();
      final file = File('${dir?.path}/received_${DateTime.now().millisecondsSinceEpoch}.pdf');
      await file.writeAsBytes(Uint8List.fromList(_receivedData));
      
      setState(() {
        _isReceiving = false;
        _status = 'File saved: ${file.path}';
      });
    } catch (e) {
      setState(() => _status = 'Save failed: ${e.toString()}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.name),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildConnectionStatus(),
            const SizedBox(height: 20),
            _buildTransferProgress(),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionStatus() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.bluetooth_connected,
          color: _status.contains('Connected') ? Colors.green : Colors.red,
        ),
        const SizedBox(width: 10),
        Text(_status, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }

  Widget _buildTransferProgress() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: _isReceiving
          ? Column(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 10),
                Text('Received ${_receivedData.lengthInBytes} bytes'),
              ],
            )
          : const SizedBox.shrink(),
    );
  }
}
