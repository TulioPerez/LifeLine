import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:fluttertoast/fluttertoast.dart';
import 'package:geolocator/geolocator.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';

void main() {
  runApp(SensorApp());
}

class SensorApp extends StatefulWidget {
  const SensorApp({super.key});

  @override
  _SensorAppState createState() => _SensorAppState();
}

// Handles to load / unload sensor stream subscriptions
class _SensorAppState extends State<SensorApp> {
  StreamSubscription? _accelSub;
  StreamSubscription? _gyroSub;
  StreamSubscription? _magnetSub;
  StreamSubscription? _baroSub;
  StreamSubscription<Position>? _gpsSub;
  StreamSubscription<NoiseReading>? _micSub;

  // IMU
  double _accX = 0.0, _accY = 0.0, _accZ = 0.0;
  double _gyroX = 0.0, _gyroY = 0.0, _gyroZ = 0.0;
  double _magX = 0.0, _magY = 0.0, _magZ = 0.0;

  // GPS
  double _latitude = 0.0;
  double _longitude = 0.0;
  double _altitude = 0.0;

  // Barometer
  double _pressure = 0.0;

  // Microphone
  final NoiseMeter _noiseMeter = NoiseMeter();
  double _micLevel = 0.0;

  bool _recording = false;
  final List<String> _recordedData = [];

  final TextEditingController _fileNameController =
  TextEditingController(text: 'sensor_data');

  // Check permissions
  Future<Map<Permission, PermissionStatus>> _checkAndRequestPermissions() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      Fluttertoast.showToast(msg: "Location services are disabled.");
    }

    final statuses = await [
      Permission.locationWhenInUse,
      Permission.microphone,
    ].request();

    if (statuses[Permission.locationWhenInUse] != PermissionStatus.granted) {
      Fluttertoast.showToast(msg: "Location permission not granted.");
    }

    if (statuses[Permission.microphone] != PermissionStatus.granted) {
      Fluttertoast.showToast(msg: "Microphone permission not granted.");
    }

    return statuses;
  }


  @override
  void initState() {
    super.initState();

  _checkAndRequestPermissions().then((statuses) {
    if (mounted && statuses[Permission.locationWhenInUse] == PermissionStatus.granted) {
      _initGPS();
    }
    if (mounted && statuses[Permission.microphone] == PermissionStatus.granted) {
      _initMic();
    }

  });

    _accelSub = accelerometerEvents.listen((event) {
      setState(() {
        _accX = event.x;
        _accY = event.y;
        _accZ = event.z;
      });
      _recordData("Accelerometer", event.x, event.y, event.z);
    });

    _magnetSub = magnetometerEvents.listen((event) {
      setState(() {
        _magX = event.x;
        _magY = event.y;
        _magZ = event.z;
      });
      _recordData("Magnetometer", event.x, event.y, event.z);
    });

    _gyroSub = gyroscopeEvents.listen((event) {
      setState(() {
        _gyroX = event.x;
        _gyroY = event.y;
        _gyroZ = event.z;
      });
      _recordData("Gyroscope", event.x, event.y, event.z);
    });

    _baroSub = SensorsPlatform.instance.barometerEventStream().listen(
      (event) {
        setState(() {
          _pressure = event.pressure;
        });
        _recordPressure(event.pressure);
      },
      onError: (error) {
        print('Barometer error: $error');
      },
      cancelOnError: true,
    );
  }

  void _recordData(String sensorType, double x, double y, double z) {
    if (_recording) {
      final now = DateTime.now().toIso8601String();
      final dataLine =
          "$now, $sensorType, X: ${x.toStringAsFixed(3)}, Y: ${y.toStringAsFixed(3)}, Z: ${z.toStringAsFixed(3)}";
      _recordedData.add(dataLine);
    }
  }

  // *** GPS Integration ***
  void _initGPS() {
    Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        distanceFilter: 1,
        accuracy: LocationAccuracy.bestForNavigation,
      ),
    ).listen((Position position) {
      setState(() {
        _latitude = position.latitude;
        _longitude = position.longitude;
        _altitude = position.altitude;
      });
      _recordGPS(position.latitude, position.longitude, position.altitude);
    });
  }

  void _recordGPS(double latitude, double longitude, double altitude) {
    if (_recording) {
      final now = DateTime.now().toIso8601String();
      final dataLine =
          "$now, GPS, Lat: ${latitude.toStringAsFixed(6)}, Long: ${longitude.toStringAsFixed(6)}, Alt: ${altitude.toStringAsFixed(2)} m";
      _recordedData.add(dataLine);
    }
  }

  // *** Barometer Integration ***
  void _recordPressure(double pressure) {
    if (_recording) {
      final now = DateTime.now().toIso8601String();
      final dataLine =
          "$now, Barometer, Pressure: ${pressure.toStringAsFixed(2)} hPa";
      _recordedData.add(dataLine);
    }
  }

  // *** Microphone Integration ***
  void _initMic() {
    try {
      _micSub = _noiseMeter.noise.listen((NoiseReading reading) {
        setState(() {
          _micLevel = reading.meanDecibel;
        });
        _recordMic(reading.meanDecibel);
      });
    } catch (err) {
      print("Mic error: $err");
    }
  }

  void _recordMic(double decibel) {
    if (_recording) {
      final now = DateTime.now().toIso8601String();
      final dataLine = "$now, Microphone, dB: ${decibel.toStringAsFixed(2)}";
      _recordedData.add(dataLine);
    }
  }


  void onError(Object e) {
    print("Mic error: $e");
  }

  // Cancel active sensor stream subscriptions and dispose controllers
  @override
  void dispose() {
    _accelSub?.cancel();
    _gyroSub?.cancel();
    _magnetSub?.cancel();
    _baroSub?.cancel();
    _gpsSub?.cancel();
    _micSub?.cancel();
    _fileNameController.dispose();
    super.dispose();
  }

  Future<void> _writeDataToFile() async {
    final file = await _localFile;
    String fileContent = _recordedData.join("\n");
    await file.writeAsString(fileContent);
    print("Data written to file: ${file.path}");
  }

  Future<void> _uploadFileToBucket() async {
    final file = await _localFile;
    if (!(await file.exists())) {
      print("File does not exist: ${file.path}");
      Fluttertoast.showToast(
        msg: "File does not exist!",
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
        fontSize: 16.0,
      );
      return;
    }

    final uploadUrl = Uri.parse(
      "https://storage.googleapis.com/test_game_public/${file.uri.pathSegments.last}",
    );

    final fileBytes = await file.readAsBytes();
    final response = await http.put(
      uploadUrl,
      headers: {'Content-Type': 'text/plain'},
      body: fileBytes,
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      print("Upload successful!");
      Fluttertoast.showToast(
        msg: "Upload successful!",
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
        fontSize: 16.0,
      );
    } else {
      Fluttertoast.showToast(
        msg: "Upload failed! Status: ${response.statusCode}",
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
        fontSize: 16.0,
      );
      print("Upload failed with status: ${response.statusCode}");
    }
  }

  Future<String> get _localPath async {
    final directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }

  Future<File> get _localFile async {
    final path = await _localPath;
    String fileName = _fileNameController.text.trim();
    if (fileName.isEmpty) fileName = 'sensor_data';
    if (!fileName.endsWith('.txt')) fileName += '.txt';
    return File('$path/$fileName');
  }

  void _startRecording() {
    setState(() {
      _recordedData.clear();
      _recording = true;
    });
  }

  void _stopRecording() async {
    setState(() {
      _recording = false;
    });
    await _writeDataToFile();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.white,
        primaryColor: Colors.red,
        appBarTheme: AppBarTheme(
          color: Colors.red,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
          iconTheme: IconThemeData(color: Colors.white),
        ),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: Text('Life Line - Sensor Data'),
          centerTitle: true,
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: SingleChildScrollView(
            child: Column(
              children: [
                _buildSensorCard(
                  "Accelerometer",
                  _accX,
                  _accY,
                  _accZ,
                  Colors.red.shade700,
                ),
                _buildSensorCard(
                  "Gyroscope",
                  _gyroX,
                  _gyroY,
                  _gyroZ,
                  Colors.red.shade500,
                ),
                _buildSensorCard(
                  "Magnetometer",
                  _magX,
                  _magY,
                  _magZ,
                  Colors.red.shade300,
                ),
                _buildSensorCard(
                  "GPS",
                  _latitude,
                  _longitude,
                  _altitude,
                  const Color.fromARGB(255, 40, 142, 14),
                ),
                _buildBarometerCard(
                  "Barometer",
                  _pressure,
                  const Color.fromARGB(255, 73, 160, 204),
                ),
                _buildMicrophoneCard(
                  "Microphone",
                  _micLevel,
                  Colors.deepPurple,
                ),
                SizedBox(height: 15),
                TextField(
                  controller: _fileNameController,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Enter filename',
                    hintText: 'sensor_data',
                  ),
                ),
                SizedBox(height: 15),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: _recording ? null : _startRecording,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                      ),
                      child: Text("Start Recording"),
                    ),
                    ElevatedButton(
                      onPressed: _recording ? _stopRecording : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                      ),
                      child: Text("Stop Recording"),
                    ),
                  ],
                ),
                SizedBox(height: 10),
                ElevatedButton(
                  onPressed: _uploadFileToBucket,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                  child: Text("Upload File to Bucket"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSensorCard(
    String title,
    double x,
    double y,
    double z,
    Color color,
  ) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: Colors.grey[200],
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            Divider(color: color, thickness: 1.5),
            SizedBox(height: 8),
            _buildSensorText("X", x, Colors.red.shade900),
            _buildSensorText("Y", y, Colors.red.shade700),
            _buildSensorText("Z", z, Colors.red.shade500),
          ],
        ),
      ),
    );
  }

  Widget _buildBarometerCard(String title, double pressure, Color color) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: Colors.grey[200],
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            Divider(color: color, thickness: 1.5),
            SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "Pressure (hPa):",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: color,
                  ),
                ),
                Text(
                  "${pressure.toStringAsFixed(2)}",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w400,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMicrophoneCard(String title, double micLevel, Color color) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: Colors.grey[200],
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold, color: color)),
            Divider(color: color, thickness: 1.5),
            SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("Level (dB):",
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w500, color: color)),
                Text("${micLevel.toStringAsFixed(2)}",
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w400,
                        color: Colors.black87)),
              ],
            ),
          ],
        ),
      ),
    );
  }


  Widget _buildSensorText(String axis, double value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            "$axis Axis:",
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
          Text(
            value.toStringAsFixed(3),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w400,
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }
}
