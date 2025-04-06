import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:fluttertoast/fluttertoast.dart';


void main() {
  runApp(SensorApp());
}

class SensorApp extends StatefulWidget {
  @override
  _SensorAppState createState() => _SensorAppState();
}

class _SensorAppState extends State<SensorApp> {
  double _accX = 0.0, _accY = 0.0, _accZ = 0.0;
  double _gyroX = 0.0, _gyroY = 0.0, _gyroZ = 0.0;
  double _magX = 0.0, _magY = 0.0, _magZ = 0.0;

  bool _recording = false;
  List<String> _recordedData = [];

  final TextEditingController _fileNameController =
  TextEditingController(text: 'sensor_data');

  @override
  void initState() {
    super.initState();

    accelerometerEvents.listen((event) {
      setState(() {
        _accX = event.x;
        _accY = event.y;
        _accZ = event.z;
      });
      _recordData("Accelerometer", event.x, event.y, event.z);
    });

    gyroscopeEvents.listen((event) {
      setState(() {
        _gyroX = event.x;
        _gyroY = event.y;
        _gyroZ = event.z;
      });
      _recordData("Gyroscope", event.x, event.y, event.z);
    });

    magnetometerEvents.listen((event) {
      setState(() {
        _magX = event.x;
        _magY = event.y;
        _magZ = event.z;
      });
      _recordData("Magnetometer", event.x, event.y, event.z);
    });
  }

  void _recordData(String sensorType, double x, double y, double z) {
    if (_recording) {
      final now = DateTime.now().toIso8601String();
      final dataLine =
          "$now, $sensorType, X: ${x.toStringAsFixed(3)}, Y: ${y.toStringAsFixed(3)}, Z: ${z.toStringAsFixed(3)}";
      _recordedData.add(dataLine);
    }
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
        "https://storage.googleapis.com/test_game_public/${file.uri.pathSegments.last}");

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
              color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
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
                    "Accelerometer", _accX, _accY, _accZ, Colors.red.shade700),
                _buildSensorCard(
                    "Gyroscope", _gyroX, _gyroY, _gyroZ, Colors.red.shade500),
                _buildSensorCard(
                    "Magnetometer", _magX, _magY, _magZ, Colors.red.shade300),
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
                      child: Text("Start Recording"),
                      style:
                      ElevatedButton.styleFrom(backgroundColor: Colors.green),
                    ),
                    ElevatedButton(
                      onPressed: _recording ? _stopRecording : null,
                      child: Text("Stop Recording"),
                      style:
                      ElevatedButton.styleFrom(backgroundColor: Colors.red),
                    ),
                  ],
                ),
                SizedBox(height: 10),
                ElevatedButton(
                  onPressed: _uploadFileToBucket,
                  child: Text("Upload File to Bucket"),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSensorCard(
      String title, double x, double y, double z, Color color) {
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
            _buildSensorText("X", x, Colors.red.shade900),
            _buildSensorText("Y", y, Colors.red.shade700),
            _buildSensorText("Z", z, Colors.red.shade500),
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
          Text("$axis Axis:",
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w500, color: color)),
          Text(value.toStringAsFixed(3),
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                  color: Colors.black87)),
        ],
      ),
    );
  }
}
