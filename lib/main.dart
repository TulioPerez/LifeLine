import 'dart:io';
import 'dart:math';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:fluttertoast/fluttertoast.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

void main() {
  runApp(const SensorApp());
}

class SensorApp extends StatefulWidget {
  const SensorApp({super.key});

  @override
  State<SensorApp> createState() => _SensorAppState();
}

class _SensorAppState extends State<SensorApp> {
  String? _userId;
  String get _bucketFilename => "${_userId ?? 'unknown'}.txt";

  StreamSubscription? _accelSub, _gyroSub, _magnetSub, _baroSub;
  StreamSubscription<Position>? _gpsSub;

  double _accX = 0, _accY = 0, _accZ = 0;
  double _gyroX = 0, _gyroY = 0, _gyroZ = 0;
  double _magX = 0, _magY = 0, _magZ = 0;
  double _pressure = 0;
  double _latitude = 0, _longitude = 0, _altitude = 0;

  bool _recording = false;
  final List<String> _recordedData = [];

  bool _auto3mMode = false;
  Timer? _auto3mTimer;
  bool _fallDetected = false;

  late Interpreter _interpreter;

  @override
  void initState() {
    super.initState();
    _loadOrCreateUserId().then((_) async {
      await _loadModel();
      _initGPS();
      _startSensorListeners();
    });
  }

  Future<void> _loadModel() async {
    _interpreter = await Interpreter.fromAsset('assets/fall_model.tflite');
    debugPrint('Model loaded successfully');
  }

  Future<void> _loadOrCreateUserId() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/user_id.txt');

    if (await file.exists()) {
      _userId = await file.readAsString();
    } else {
      final randomId = (100000000000 + DateTime.now().millisecondsSinceEpoch * 1000 + Random().nextInt(999999)).toString();
      await file.writeAsString(randomId);
      _userId = randomId;
    }
    debugPrint('Assigned User ID: $_userId');
  }

  void _startSensorListeners() {
    _accelSub = accelerometerEvents.listen((e) {
      setState(() {
        _accX = e.x;
        _accY = e.y;
        _accZ = e.z;
      });
      _maybeRecord('Accelerometer', [e.x, e.y, e.z]);
    });

    _gyroSub = gyroscopeEvents.listen((e) {
      setState(() {
        _gyroX = e.x;
        _gyroY = e.y;
        _gyroZ = e.z;
      });
      _maybeRecord('Gyroscope', [e.x, e.y, e.z]);
    });

    _magnetSub = magnetometerEvents.listen((e) {
      setState(() {
        _magX = e.x;
        _magY = e.y;
        _magZ = e.z;
      });
      _maybeRecord('Magnetometer', [e.x, e.y, e.z]);
    });

    _baroSub = SensorsPlatform.instance.barometerEventStream().listen(
          (e) {
        setState(() => _pressure = e.pressure);
        if (_recording) {
          final now = DateTime.now().toIso8601String();
          _recordedData.add("$now, Barometer, Pressure: ${e.pressure.toStringAsFixed(2)} hPa");
        }
      },
      onError: (err) => debugPrint('Barometer error: $err'),
      cancelOnError: true,
    );
  }

  void _initGPS() {
    _gpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        distanceFilter: 1,
        accuracy: LocationAccuracy.bestForNavigation,
      ),
    ).listen((pos) {
      setState(() {
        _latitude = pos.latitude;
        _longitude = pos.longitude;
        _altitude = pos.altitude;
      });
      if (_recording) {
        final now = DateTime.now().toIso8601String();
        _recordedData.add("$now, GPS, Lat: ${pos.latitude.toStringAsFixed(6)}, Long: ${pos.longitude.toStringAsFixed(6)}, Alt: ${pos.altitude.toStringAsFixed(2)} m");
      }
    });
  }

  void _maybeRecord(String sensor, List<double> vals) {
    final now = DateTime.now().toIso8601String();
    final parts = vals.map((v) => v.toStringAsFixed(3)).toList();
    _recordedData.add("$now, $sensor, X: ${parts[0]}, Y: ${parts[1]}, Z: ${parts[2]}");

    if (_auto3mMode && sensor == 'Accelerometer') {
      _runInference(vals);
    }
  }

  void _runInference(List<double> accelVals) {
    final input = [accelVals];
    final output = List.generate(1, (_) => List.filled(1, 0));
    _interpreter.run(input, output);

    if (output[0][0] == 1) {
      _fallDetected = true;
      debugPrint("Fall detected by model.");
    }
  }

  void _startAuto3mCycle() {
    setState(() {
      _auto3mMode = true;
      _fallDetected = false;
    });

    Fluttertoast.showToast(msg: "Lifeline activated. Monitoring...");

    _auto3mTimer = Timer.periodic(const Duration(minutes: 3), (timer) async {
      if (_fallDetected) {
        Fluttertoast.showToast(msg: "Fall detected — sending file...");
        await _saveDataToFileAndSend();
        _fallDetected = false;
      } else {
        Fluttertoast.showToast(msg: "No fall detected in last 3 mins.");
      }
    });
  }

  void _stopAuto3mCycle() {
    _auto3mTimer?.cancel();
    setState(() {
      _auto3mMode = false;
      _fallDetected = false;
    });
    Fluttertoast.showToast(msg: "Lifeline stopped.");
  }

  Future<void> _saveDataToFileAndSend() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$_bucketFilename');
    await file.writeAsString(_recordedData.join('\n'));

    // Simulated upload
    Fluttertoast.showToast(msg: "File saved and sent (simulated)");
    debugPrint("File sent: ${file.path}");
  }

  void _deleteFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$_bucketFilename');
    if (await file.exists()) {
      await file.delete();
      Fluttertoast.showToast(msg: 'Emergency file deleted.');
    } else {
      Fluttertoast.showToast(msg: 'No emergency file found.');
    }
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    _gyroSub?.cancel();
    _magnetSub?.cancel();
    _baroSub?.cancel();
    _gpsSub?.cancel();
    _auto3mTimer?.cancel();
    super.dispose();
  }

  Widget _buildSensorCard(String title, double x, double y, double z, Color color) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
            Divider(color: color, thickness: 1.5),
            Text("X: ${x.toStringAsFixed(3)}"),
            Text("Y: ${y.toStringAsFixed(3)}"),
            Text("Z: ${z.toStringAsFixed(3)}"),
          ],
        ),
      ),
    );
  }

  Widget _buildBarometerCard(String title, double pressure, Color color) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
            Divider(color: color, thickness: 1.5),
            Text("Pressure (hPa): ${pressure.toStringAsFixed(2)}"),
          ],
        ),
      ),
    );
  }

  Widget _buildGpsCard() {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("GPS", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.green)),
            const Divider(color: Colors.green, thickness: 1.5),
            Text("Lat: ${_latitude.toStringAsFixed(6)}"),
            Text("Lon: ${_longitude.toStringAsFixed(6)}"),
            Text("Alt: ${_altitude.toStringAsFixed(2)} m"),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primaryColor: Colors.red),
      home: Scaffold(
        appBar: AppBar(title: const Text('Life Line - Sensor Data'), centerTitle: true),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Column(
              children: [
                _buildSensorCard("Accelerometer", _accX, _accY, _accZ, Colors.red.shade700),
                _buildSensorCard("Gyroscope", _gyroX, _gyroY, _gyroZ, Colors.red.shade500),
                _buildSensorCard("Magnetometer", _magX, _magY, _magZ, Colors.red.shade300),
                _buildBarometerCard("Barometer", _pressure, Colors.blueAccent),
                _buildGpsCard(),
                const SizedBox(height: 30),
                ElevatedButton(
                  onPressed: _auto3mMode ? _stopAuto3mCycle : _startAuto3mCycle,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  child: Text(_auto3mMode ? "Stop Lifeline" : "Activate Lifeline"),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _deleteFile,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade800,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  child: const Text("Delete Emergency"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
