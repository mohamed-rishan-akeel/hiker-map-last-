import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import 'package:flutter_dotenv/flutter_dotenv.dart';

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
      title: 'Offline Hiking Map',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
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

  Future<void> _initOfflineMap() async {
    _offlineManager = await mapbox.OfflineManager.create();
    _tileStore = await mapbox.TileStore.createDefault();
    debugPrint('Offline map resources initialized');
  }

  Future<void> _downloadMapArea(String areaKey) async {
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
  mapbox.PolylineAnnotationManager? _polylineManager;
  mapbox.PolylineAnnotation? _pathAnnotation;
  double _latitude = 0.0;
  double _longitude = 0.0;
  double _prevLat = 0.0;
  double _prevLng = 0.0;
  List<mapbox.Point> _pathPoints = [];
  bool _followMode = false;

  // Simulated stores with dummy data
  final Map<String, List<String>> _stores = {
    'inbox': [
      '1:Hello Akila, how are you?',
      '3:Ah yes, isn\'t React Native easy to work with?',
      '5:Is that why you switched to Flutter?',
      '6:Amazinggggggggggg.........'
    ],
    'sendbox': [
      '2:I\'m doing well Raju, these days I\'m building a Flutter app.',
      '4:Ah, I know, but I couldn\'t connect Mapbox.',
      '7:Good Night!'
    ],
    'gps': [
      '1.22345,27.332233',
      '2.22345,27.332233',
      '3.22345,27.332233',
      '4.22345,27.332233',
      '5.22345,27.332233',
      '6.22345,27.332233'
    ],
  };
  final Map<String, int> _sizes = {
    'inbox': 4,
    'sendbox': 3,
    'gps': 6
  };
  Map<String, int> _selectedIndices = {'inbox': 0, 'sendbox': 0, 'gps': 0};
  Map<String, String> _data = {'inbox': '', 'sendbox': '', 'gps': ''};
  Map<String, String> _notifications = {'inbox': '', 'sendbox': '', 'gps': ''};
  String _status = 'Ready';

  static const double _distanceThreshold = 10.0; // Meters for significant change

  @override
  void initState() {
    super.initState();
    _latitude = widget.center.coordinates.lat.toDouble();
    _longitude = widget.center.coordinates.lng.toDouble();
    _prevLat = _latitude;
    _prevLng = _longitude;
    _pathPoints.add(mapbox.Point(coordinates: mapbox.Position(_longitude, _latitude)));
    // Plot all initial GPS coordinates
    _plotAllGpsCoordinates();
  }

  void _plotAllGpsCoordinates() {
    for (int i = 0; i < _stores['gps']!.length; i++) {
      _selectedIndices['gps'] = i;
      _readData('gps', initialPlot: true);
    }
    // Set to last coordinate for display
    _selectedIndices['gps'] = _stores['gps']!.length - 1;
    _readData('gps');
  }

  void _readData(String store, {bool initialPlot = false}) {
    final index = _selectedIndices[store]!;
    if (index >= 0 && index < _stores[store]!.length) {
      final dataStr = _stores[store]![index];
      setState(() {
        _data[store] = dataStr;
        _status = 'Read $store data: $dataStr';
      });
      if (store == 'gps') {
        try {
          var coords = dataStr.split(",");
          if (coords.length != 2) throw FormatException('Invalid GPS data format');
          final lat = double.parse(coords[0]);
          final lng = double.parse(coords[1]);
          if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
            throw RangeError('GPS coordinates out of valid range');
          }
          if (initialPlot || index == _stores['gps']!.length - 1) {
            _updatePosition(lat, lng);
            _addOrUpdateLocationMarker(lat, lng);
          }
        } catch (e) {
          debugPrint('Invalid GPS data: $e');
          setState(() {
            _status = 'Invalid GPS data: $e';
          });
        }
      }
    } else {
      setState(() {
        _data[store] = '';
        _status = 'Invalid $store index: $index';
      });
    }
  }

  void _simulateNotification(String store) {
    if (store != 'gps') return; // Only simulate for gps
    // Simulate adding a new coordinate dynamically
    final newIndex = _stores['gps']!.length + 1;
    final newCoord = '${newIndex}.22345,27.332233';
    setState(() {
      _stores['gps']!.add(newCoord);
      _sizes['gps'] = _stores['gps']!.length;
      _selectedIndices[store] = _stores['gps']!.length - 1;
      _notifications[store] = 'Simulated index: ${_selectedIndices[store]}';
      _status = 'Simulated $store notification for index: ${_selectedIndices[store]}';
    });
    _readData(store);
  }

  void _updatePosition(double newLat, double newLng) {
    final distance = _calculateDistance(_prevLat, _prevLng, newLat, newLng);
    if (distance > _distanceThreshold || _pathPoints.length == 1) {
      setState(() {
        _latitude = newLat;
        _longitude = newLng;
        _prevLat = newLat;
        _prevLng = newLng;
        _pathPoints.add(mapbox.Point(coordinates: mapbox.Position(newLng, newLat)));
        _updatePath();
        if (_followMode) {
          _smoothUpdateCamera(newLat, newLng);
        }
      });
    }
  }

  double _calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0; // Earth radius in meters
    final dLat = (lat2 - lat1) * pi / 180.0;
    final dLon = (lon2 - lon1) * pi / 180.0;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180.0) * cos(lat2 * pi / 180.0) * sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  Future<void> _smoothUpdateCamera(double lat, double lng) async {
    if (_mapboxMap != null) {
      final currentCamera = await _mapboxMap!.getCameraState();
      await _mapboxMap!.easeTo(
        mapbox.CameraOptions(
          center: mapbox.Point(coordinates: mapbox.Position(lng, lat)),
          zoom: currentCamera.zoom,
          bearing: currentCamera.bearing,
          pitch: currentCamera.pitch,
        ),
        mapbox.MapAnimationOptions(duration: 500),
      );
    }
  }

  Future<void> _addOrUpdateLocationMarker(double lat, double lng) async {
    if (_annotationManager == null) return;
    final point = mapbox.Point(coordinates: mapbox.Position(lng, lat));
    if (_locationAnnotation == null) {
      final options = mapbox.CircleAnnotationOptions(
        geometry: point,
        circleColor: 0xFF0000FF,
        circleRadius: 12.0,
        circleStrokeColor: 0xFFFFFFFF,
        circleStrokeWidth: 2.0,
      );
      _locationAnnotation = await _annotationManager?.create(options);
    } else {
      _locationAnnotation?.geometry = point;
      await _annotationManager?.update(_locationAnnotation!);
    }
  }

  Future<void> _updatePath() async {
    if (_polylineManager == null) return;
    if (_pathAnnotation == null) {
      final options = mapbox.PolylineAnnotationOptions(
        geometry: mapbox.LineString(coordinates: _pathPoints.map((p) => p.coordinates).toList()),
        lineColor: 0xFF0000FF,
        lineWidth: 4.0,
      );
      _pathAnnotation = await _polylineManager?.create(options);
    } else {
      _pathAnnotation?.geometry = mapbox.LineString(coordinates: _pathPoints.map((p) => p.coordinates).toList());
      await _polylineManager?.update(_pathAnnotation!);
    }
  }

  void _toggleFollowMode() {
    setState(() {
      _followMode = !_followMode;
      if (_followMode) {
        _smoothUpdateCamera(_latitude, _longitude);
      }
    });
  }

  void _showMessagesWindow() {
    // Combine inbox and sendbox messages with their indices
    List<Map<String, dynamic>> messages = [];
    _stores['inbox']!.asMap().forEach((index, message) {
      messages.add({
        'index': int.parse(message.split(':')[0]),
        'text': message.substring(message.indexOf(':') + 1),
        'isInbox': true
      });
    });
    _stores['sendbox']!.asMap().forEach((index, message) {
      messages.add({
        'index': int.parse(message.split(':')[0]),
        'text': message.substring(message.indexOf(':') + 1),
        'isInbox': false
      });
    });
    // Sort by index for chronological order
    messages.sort((a, b) => a['index'].compareTo(b['index']));

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Messages and GPS'),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Current GPS: $_latitude, $_longitude',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      return Align(
                        alignment: message['isInbox']
                            ? Alignment.centerLeft
                            : Alignment.centerRight,
                        child: Container(
                          margin: const EdgeInsets.symmetric(
                              vertical: 4, horizontal: 8),
                          padding: const EdgeInsets.all(10),
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.6,
                          ),
                          decoration: BoxDecoration(
                            color: message['isInbox']
                                ? Colors.grey[300]
                                : Colors.blue[200],
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 4,
                                offset: const Offset(2, 2),
                              ),
                            ],
                          ),
                          child: Text(
                            message['text'],
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        decoration: const InputDecoration(
                          labelText: 'Select gps Index',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                        onSubmitted: (value) {
                          int? index = int.tryParse(value);
                          if (index != null && index >= 0 && index < _sizes['gps']!) {
                            setState(() {
                              _selectedIndices['gps'] = index;
                              _status = 'Selected gps index: $index';
                            });
                            _readData('gps');
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () => _readData('gps'),
                      child: const Text('Read Data'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () => _simulateNotification('gps'),
                      child: const Text('Simulate Notification'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
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
            _polylineManager = await mapboxMap.annotations.createPolylineAnnotationManager();
            _addOrUpdateLocationMarker(_latitude, _longitude);
            _updatePath();
          },
        ),
        Positioned(
          bottom: 16,
          right: 16,
          child: Column(
            children: [
              FloatingActionButton(
                onPressed: _showMessagesWindow,
                child: const Icon(Icons.add),
              ),
              const SizedBox(height: 8),
              FloatingActionButton(
                onPressed: _toggleFollowMode,
                child: Icon(_followMode ? Icons.location_off : Icons.location_on),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    if (_locationAnnotation != null) {
      _annotationManager?.delete(_locationAnnotation!);
    }
    if (_pathAnnotation != null) {
      _polylineManager?.delete(_pathAnnotation!);
    }
    _annotationManager?.deleteAll();
    _polylineManager?.deleteAll();
    super.dispose();
  }
}