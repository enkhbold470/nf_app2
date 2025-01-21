import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'dart:io' show Platform;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EEG BLE Monitor',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  FlutterBluePlus flutterBluePlus = FlutterBluePlus();
  List<ScanResult> scanResults = [];
  bool isScanning = false;
  BluetoothDevice? connectedDevice;
  List<String> eegData = [];
  bool isConnected = false;
  StreamSubscription? connectionStateSubscription;
  StreamSubscription? characteristicSubscription;
  StreamSubscription? bluetoothStateSubscription;
  final ScrollController _scrollController = ScrollController();

  final String EEG_SERVICE_UUID =
      "4fafc201-1fb5-459e-8fcc-c5c9c331914b"; // Replace with actual UUID

  @override
  void initState() {
    super.initState();
    _initializeBluetooth();
  }

  Future<void> _initializeBluetooth() async {
    if (Platform.isAndroid) {
      await Permission.bluetooth.request();
      await Permission.bluetoothScan.request();
      await Permission.bluetoothConnect.request();
      await Permission.location.request();
    }
  }

  void startScan() {
    // if (Platform.isWeb) {
    //   _showSnackBar('Scanning not supported on web');
    //   return;
    // }

    setState(() {
      scanResults.clear();
      isScanning = true;
    });

    FlutterBluePlus.startScan(timeout: const Duration(seconds: 4)).then((_) {
      setState(() {
        isScanning = false;
      });
    }).catchError((error) {
      setState(() {
        isScanning = false;
      });
      _showSnackBar('Failed to start scan: $error');
    });

    FlutterBluePlus.scanResults.listen((results) {
      setState(() {
        scanResults = results;
      });
    });
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      await device.connect();
      setState(() {
        connectedDevice = device;
        isConnected = true;
      });

      connectionStateSubscription = device.state.listen((state) {
        if (state == BluetoothDeviceState.disconnected) {
          setState(() {
            isConnected = false;
            connectedDevice = null;
          });
          _showSnackBar('Device disconnected');
        }
      });

      List<BluetoothService> services = await device.discoverServices();
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.properties.notify) {
            await characteristic.setNotifyValue(true);
            characteristicSubscription = characteristic.value.listen((value) {
              _handleEEGData(value);
            });
          }
        }
      }
    } catch (e) {
      _showSnackBar('Failed to connect: ${e.toString()}');
    }
  }

  void _handleEEGData(List<int> data) {
    setState(() {
      eegData.add(utf8.decode(data));
      if (eegData.length > 100) {
        eegData.removeAt(0);
      }
    });
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  Future<void> disconnectDevice() async {
    if (connectedDevice != null) {
      await connectedDevice!.disconnect();
      setState(() {
        connectedDevice = null;
        isConnected = false;
        eegData.clear();
      });
      connectionStateSubscription?.cancel();
      characteristicSubscription?.cancel();
    }
  }

  Future<void> saveData() async {
    try {
      final String jsonData = json.encode(eegData);
      // Save to local storage or file system
      _showSnackBar('Data saved successfully');
    } catch (e) {
      _showSnackBar('Failed to save data: ${e.toString()}');
    }
  }

  Future<void> sendDataToServer() async {
    try {
      final response = await http.post(
        Uri.parse('http://your-flask-server/eeg-data'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'data': eegData}),
      );

      if (response.statusCode == 200) {
        _showSnackBar('Data sent successfully');
      } else {
        throw Exception('Failed to send data');
      }
    } catch (e) {
      _showSnackBar('Failed to send data: ${e.toString()}');
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('EEG BLE Monitor'),
        actions: [
          IconButton(
            icon:
                Icon(isConnected ? Icons.bluetooth_connected : Icons.bluetooth),
            onPressed: null,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  icon: Icon(isScanning ? Icons.stop : Icons.search),
                  label: Text(isScanning ? 'Stop Scan' : 'Start Scan'),
                  onPressed:
                      isScanning ? () => FlutterBluePlus.stopScan() : startScan,
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.save),
                  label: const Text('Save Data'),
                  onPressed: isConnected ? saveData : null,
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.cloud_upload),
                  label: const Text('Send Data'),
                  onPressed: isConnected ? sendDataToServer : null,
                ),
              ],
            ),
          ),
          if (isScanning || (!isConnected && scanResults.isNotEmpty))
            Expanded(
              flex: 1,
              child: ListView.builder(
                itemCount: scanResults.length,
                itemBuilder: (context, index) {
                  final result = scanResults[index];
                  return ListTile(
                    title: Text(result.device.name.isEmpty
                        ? 'Unknown Device'
                        : result.device.name),
                    subtitle: Text(result.device.id.toString()),
                    trailing: ElevatedButton(
                      child: const Text('Connect'),
                      onPressed: () => connectToDevice(result.device),
                    ),
                  );
                },
              ),
            ),
          if (isConnected)
            Expanded(
              flex: 2,
              child: Container(
                margin: const EdgeInsets.all(8.0),
                padding: const EdgeInsets.all(8.0),
                decoration: BoxDecoration(
                  color: Colors.black,
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: ListView.builder(
                  controller: _scrollController,
                  itemCount: eegData.length,
                  itemBuilder: (context, index) {
                    return Text(
                      eegData[index],
                      style: const TextStyle(
                        color: Colors.green,
                        fontFamily: 'Courier',
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: isConnected
          ? FloatingActionButton(
              onPressed: disconnectDevice,
              child: const Icon(Icons.bluetooth_disabled),
            )
          : null,
    );
  }

  @override
  void dispose() {
    bluetoothStateSubscription?.cancel();
    connectionStateSubscription?.cancel();
    characteristicSubscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }
}
