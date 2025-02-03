import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:developer';
// supabase
import 'package:supabase_flutter/supabase_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
      url: String.fromEnvironment('supabase_url', defaultValue: ''),
      anonKey: String.fromEnvironment('supabase_anon_key', defaultValue: ''));
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

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
  const HomePage({super.key});

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
  final ScrollController _scrollController = ScrollController();

  //supabase
  final supabase = Supabase.instance.client; // Add this line

  // BLE Configuration
  // final String DEVICE_NAME = "EEG-snag-hat-s3";
  final String SERVICE_UUID = "7d0913a6-cc3e-443d-9b83-b0b84faf685f";
  final String CHARACTERISTIC_UUID = "2334502e-ca45-4f74-855d-e9bb776802ad";

// BLE UUIDs
// #define SERVICE_UUID "7d0913a6-cc3e-443d-9b83-b0b84faf685f"
// #define CHARACTERISTIC_UUID "2334502e-ca45-4f74-855d-e9bb776802ad"
  @override
  void initState() {
    super.initState();
    _initializeBluetooth();
    _setupAuthListener(); // Add this
  }

  // Add this new method
  void _setupAuthListener() {
    supabase.auth.onAuthStateChange.listen((data) {
      final AuthChangeEvent event = data.event;
      final Session? session = data.session;
      log('Auth state changed: $event');
      if (session != null) {
        log('User email: ${session.user.email}');
      }
    });
  }

  // Add these new methods for auth operations
  Future<void> signUp(String email, String password) async {
    try {
      await supabase.auth.signUp(
        email: email,
        password: password,
      );
      _showSnackBar('Sign up successful! Please check your email.');
    } catch (e) {
      _showSnackBar('Sign up failed: ${e.toString()}');
    }
  }

  Future<void> signIn(String email, String password) async {
    try {
      await supabase.auth.signInWithPassword(
        email: email,
        password: password,
      );
      _showSnackBar('Login successful!');
    } catch (e) {
      _showSnackBar('Login failed: ${e.toString()}');
    }
  }

  Future<void> signInWithMagicLink(String email) async {
    try {
      await supabase.auth.signInWithOtp(email: email);
      _showSnackBar('Magic link sent to $email');
    } catch (e) {
      _showSnackBar('Failed to send magic link: ${e.toString()}');
    }
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
        // Filter devices by name
        scanResults =
            results.where((result) => result.device.name.isNotEmpty).toList();
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
        if (service.uuid.toString() == SERVICE_UUID) {
          for (var characteristic in service.characteristics) {
            if (characteristic.uuid.toString() == CHARACTERISTIC_UUID &&
                characteristic.properties.notify) {
              await characteristic.setNotifyValue(true);
              characteristicSubscription = characteristic.value.listen((value) {
                _handleEEGData(value);
              });
            }
          }
        }
      }
    } catch (e) {
      _showSnackBar('Failed to connect: ${e.toString()}');
    }
  }

  void _handleEEGData(List<int> data) {
    setState(() {
      eegData.add(
          data.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' '));
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

  Future<void> sendDataToServer() async {
    try {
      log('Sending data: $eegData');
      final response = await http.post(
        Uri.parse(String.fromEnvironment('server_url',
            defaultValue: 'https://clean-eeg.onrender.com/')),
        headers: {
          'Content-Type': 'application/json',
        },
        body: json.encode({'data': eegData}),
      );

      if (response.statusCode == 200) {
        _showSnackBar('Data sent successfully');
      } else {
        throw Exception('Failed to send data: ${response.statusCode}');
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
          PopupMenuButton<String>(
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'signIn',
                child: Text('Sign In'),
              ),
              const PopupMenuItem(
                value: 'signUp',
                child: Text('Sign Up'),
              ),
              const PopupMenuItem(
                value: 'magicLink',
                child: Text('Magic Link'),
              ),
            ],
            onSelected: (value) async {
              final emailController = TextEditingController();
              final passwordController = TextEditingController();

              await showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(value == 'magicLink' ? 'Enter Email' : 'Login'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: emailController,
                        decoration: const InputDecoration(labelText: 'Email'),
                      ),
                      if (value != 'magicLink')
                        TextField(
                          controller: passwordController,
                          decoration:
                              const InputDecoration(labelText: 'Password'),
                          obscureText: true,
                        ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () {
                        Navigator.pop(context);
                      },
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () async {
                        Navigator.pop(context);
                        final email = emailController.text;
                        final password = passwordController.text;

                        if (value == 'signIn') {
                          await signIn(email, password);
                        } else if (value == 'signUp') {
                          await signUp(email, password);
                        } else if (value == 'magicLink') {
                          await signInWithMagicLink(email);
                        }
                      },
                      child: const Text('Submit'),
                    ),
                  ],
                ),
              );
            },
          ),
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
    connectionStateSubscription?.cancel();
    characteristicSubscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }
}
