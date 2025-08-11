import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:permission_handler/permission_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: ".env");
    final accessToken = dotenv.env['MAPBOX_ACCESS_TOKEN'];
    if (accessToken == null || accessToken.isEmpty) {
      throw Exception('Mapbox access token is missing or invalid in .env file');
    }
    mapbox.MapboxOptions.setAccessToken(accessToken);
  } catch (e) {
    debugPrint('Failed to initialize Mapbox: $e');
    runApp(const ErrorApp(message: 'Failed to load Mapbox configuration'));
    return;
  }
  runApp(const MyApp());
}

class ErrorApp extends StatelessWidget {
  final String message;
  const ErrorApp({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(child: Text(message)),
      ),
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: const HikingMapApp(),
    );
  }
}

class HikingMapApp extends StatefulWidget {
  const HikingMapApp({super.key});
  @override
  State createState() => _HikingMapAppState();
}

class _HikingMapAppState extends State<HikingMapApp> {
  mapbox.TileStore? _tileStore;
  mapbox.OfflineManager? _offlineManager;
  String _selectedArea = 'colombo';
  final Map<String, Map<String, dynamic>> _hikingAreas = {
    'colombo': {
      'name': 'Colombo',
      'center': mapbox.Point(coordinates: mapbox.Position(79.8612, 6.9271)),
      'geometry': {
        'type': 'Polygon',
        'coordinates': [
          [
            [79.80, 6.85],
            [79.92, 6.85],
            [79.92, 7.00],
            [79.80, 7.00],
            [79.80, 6.85]
          ]
        ]
      },
    },
    'sinhartop': {
      'name': 'Sinharaja Forest',
      'center': mapbox.Point(coordinates: mapbox.Position(80.5000, 6.4167)),
      'geometry': {
        'type': 'Polygon',
        'coordinates': [
          [
            [80.45, 6.38],
            [80.55, 6.38],
            [80.55, 6.45],
            [80.45, 6.45],
            [80.45, 6.38]
          ]
        ]
      },
    },
  };

  @override
  void initState() {
    super.initState();
    _initOfflineMap();
  }

  _initOfflineMap() async {
    _offlineManager = await mapbox.OfflineManager.create();
    _tileStore = await mapbox.TileStore.createDefault();
    debugPrint('Offline map resources initialized');
  }

  _downloadMapArea(String areaKey) async {
    if (!mounted) return;
    final area = _hikingAreas[areaKey]!;
    final tileRegionId = '$areaKey-tile-region';
    final tileRegionLoadOptions = mapbox.TileRegionLoadOptions(
      geometry: area['geometry'],
      descriptorsOptions: [
        mapbox.TilesetDescriptorOptions(
          styleURI: mapbox.MapboxStyles.SATELLITE_STREETS,
          minZoom: 0,
          maxZoom: 14,
        ),
      ],
      acceptExpired: true,
      networkRestriction: mapbox.NetworkRestriction.NONE,
    );
    final stylePackLoadOptions = mapbox.StylePackLoadOptions(
      glyphsRasterizationMode:
          mapbox.GlyphsRasterizationMode.IDEOGRAPHS_RASTERIZED_LOCALLY,
      metadata: {"tag": areaKey},
      acceptExpired: false,
    );

    try {
      await _offlineManager?.loadStylePack(
        mapbox.MapboxStyles.SATELLITE_STREETS,
        stylePackLoadOptions,
        (progress) {
          debugPrint('Style pack progress: ${progress.completedResourceCount}/${progress.requiredResourceCount}');
        },
      );
      await _tileStore?.loadTileRegion(
        tileRegionId,
        tileRegionLoadOptions,
        (progress) {
          debugPrint('Tile region progress: ${progress.completedResourceCount}/${progress.requiredResourceCount}');
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Map for ${area['name']} downloaded successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Offline Hiking Map')),
      body: Column(
        children: [
          DropdownButton<String>(
            value: _selectedArea,
            items: _hikingAreas.keys.map((String key) {
              return DropdownMenuItem<String>(
                value: key,
                child: Text(_hikingAreas[key]!['name']),
              );
            }).toList(),
            onChanged: (String? newValue) {
              setState(() {
                _selectedArea = newValue!;
              });
            },
          ),
          TextButton(
            onPressed: () => _downloadMapArea(_selectedArea),
            child: Text('Download Map for ${_hikingAreas[_selectedArea]!['name']}'),
          ),
          Expanded(
            child: OfflineMapWidget(
              areaKey: _selectedArea,
              center: _hikingAreas[_selectedArea]!['center'],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}

class OfflineMapWidget extends StatefulWidget {
  final String areaKey;
  final mapbox.Point center;
  const OfflineMapWidget({super.key, required this.areaKey, required this.center});

  @override
  State createState() => _OfflineMapWidgetState();
}

class _OfflineMapWidgetState extends State<OfflineMapWidget> {
  mapbox.MapboxMap? _mapboxMap;
  mapbox.CircleAnnotationManager? _annotationManager;
  mapbox.CircleAnnotation? _locationAnnotation;
  CentralManager? _centralManager;
  Peripheral? _connectedPeripheral;
  String _latitude = "0.0";
  String _longitude = "0.0";
  Timer? _timer;
  List<DiscoveredEventArgs> _discoveredDevices = [];
  bool _isScanning = false;
  StreamSubscription<DiscoveredEventArgs>? _discoverySubscription;
  StreamSubscription<GATTCharacteristicNotifiedEventArgs>? _notificationSubscription;

  // Assume Nordic UART Service UUIDs for ESP32 serial-like communication
  final UUID _serviceUUID = UUID.fromString('6e400001-b5a3-f393-e0a9-e50e24dcca9e');
  final UUID _rxUUID = UUID.fromString('6e400003-b5a3-f393-e0a9-e50e24dcca9e'); // Notify characteristic

  @override
  void initState() {
    super.initState();
    _latitude = widget.center.coordinates.lat.toString();
    _longitude = widget.center.coordinates.lng.toString();
    _initBluetooth();
    _timer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _updateCamera();
    });
  }

  Future<void> _initBluetooth() async {
    _centralManager = CentralManager();
    try {
      // Request permissions
      final permissions = await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ].request();

      if (!permissions.values.every((status) => status.isGranted)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Bluetooth and location permissions are required')),
          );
        }
        return;
      }

      final state = _centralManager!.state;
      if (state != BluetoothLowEnergyState.poweredOn) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Bluetooth is not enabled')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Bluetooth initialization failed: $e')),
        );
      }
    }
  }

  void _updateCamera() {
    if (_mapboxMap != null) {
      try {
        final lat = double.parse(_latitude);
        final lng = double.parse(_longitude);
        _mapboxMap?.setCamera(mapbox.CameraOptions(
          center: mapbox.Point(coordinates: mapbox.Position(lng, lat)),
          zoom: 10.0,
        ));
        _addOrUpdateLocationMarker(lat, lng);
      } catch (e) {
        debugPrint('Invalid coordinates: $e');
      }
    }
  }

  Future<void> _addOrUpdateLocationMarker(double lat, double lng) async {
    if (_annotationManager == null) return;

    final point = mapbox.Point(coordinates: mapbox.Position(lng, lat));

    if (_locationAnnotation == null) {
      final options = mapbox.CircleAnnotationOptions(
        geometry: point,
        circleColor: 0xFFFF0000, // Red
        circleRadius: 10.0,
        circleStrokeColor: 0xFFFFFFFF, // White
        circleStrokeWidth: 2.0,
      );
      _locationAnnotation = await _annotationManager?.create(options);
    } else {
      _locationAnnotation?.geometry = point;
      await _annotationManager?.update(_locationAnnotation!);
    }
  }

  Future<void> _scanForDevices() async {
    if (_centralManager == null || _isScanning) return;

    setState(() {
      _isScanning = true;
      _discoveredDevices = [];
    });

    try {
      _discoverySubscription = _centralManager!.discovered.listen((DiscoveredEventArgs event) {
        if (!_discoveredDevices.any((d) => d.peripheral.uuid == event.peripheral.uuid)) {
          setState(() {
            _discoveredDevices.add(event);
          });
        }
      });

      await _centralManager!.startDiscovery();
      await Future.delayed(const Duration(seconds: 10)); // Scan for 10 seconds
      await _centralManager!.stopDiscovery();

      setState(() {
        _isScanning = false;
      });

      if (_discoveredDevices.isNotEmpty) {
        _showDeviceSelectionDialog();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No devices found')),
          );
        }
      }
    } catch (e) {
      setState(() {
        _isScanning = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Scan failed: $e')),
        );
      }
    }
  }

  void _showDeviceSelectionDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Select Bluetooth Device'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _discoveredDevices.length,
              itemBuilder: (context, index) {
                final event = _discoveredDevices[index];
                return ListTile(
                  title: Text(event.advertisement.name ?? 'Unknown'),
                  subtitle: Text(event.peripheral.uuid.toString()),
                  onTap: () {
                    Navigator.pop(context);
                    _connectToDevice(event.peripheral);
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }

  Future<void> _connectToDevice(Peripheral peripheral) async {
    try {
      await _centralManager!.connect(peripheral);
      _connectedPeripheral = peripheral;

      // Discover services
      final services = await _centralManager!.discoverGATT(peripheral);
      final service = services.firstWhere(
        (s) => s.uuid == _serviceUUID,
        orElse: () => throw Exception('Service not found'),
      );
      final characteristic = service.characteristics.firstWhere(
        (c) => c.uuid == _rxUUID,
        orElse: () => throw Exception('Characteristic not found'),
      );

      // Set up notifications
      await _centralManager!.setCharacteristicNotifyState(peripheral, characteristic, state: true);
      _notificationSubscription = _centralManager!.characteristicNotified.listen((GATTCharacteristicNotifiedEventArgs event) {
        if (event.characteristic.uuid == _rxUUID) {
          try {
            String received = utf8.decode(event.value).trim();
            var coords = received.split(",");
            if (coords.length != 2) {
              throw FormatException('Invalid GPS data format');
            }
            final lat = double.parse(coords[0]);
            final lng = double.parse(coords[1]);
            if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
              throw RangeError('GPS coordinates out of valid range');
            }
            setState(() {
              _latitude = coords[0];
              _longitude = coords[1];
              _updateCamera();
            });
          } catch (e) {
            debugPrint('Invalid GPS data: $e');
          }
        }
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connected to ${peripheral.uuid}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        mapbox.MapWidget(
          key: ValueKey(widget.areaKey),
          styleUri: mapbox.MapboxStyles.SATELLITE_STREETS,
          cameraOptions: mapbox.CameraOptions(
            center: widget.center,
            zoom: 10.0,
          ),
          onMapCreated: (mapboxMap) async {
            _mapboxMap = mapboxMap;
            _annotationManager = await mapboxMap.annotations.createCircleAnnotationManager();
            _updateCamera();
          },
        ),
        Positioned(
          bottom: 16,
          right: 16,
          child: FloatingActionButton(
            onPressed: _isScanning ? null : _scanForDevices,
            child: _isScanning
                ? const CircularProgressIndicator(color: Colors.white)
                : const Icon(Icons.bluetooth),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _discoverySubscription?.cancel();
    _notificationSubscription?.cancel();
    if (_connectedPeripheral != null && _centralManager != null) {
      _centralManager!.disconnect(_connectedPeripheral!);
    }
    if (_locationAnnotation != null) {
      _annotationManager?.delete(_locationAnnotation!);
    }
    _annotationManager?.deleteAll();
    super.dispose();
  }
}