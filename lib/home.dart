import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart'; // Our animation powerhouse!
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:lottie/lottie.dart' hide Marker; // For a touch of celestial motion
import 'profile.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// Helper class to hold parsed location info
class ParsedLocation {
  final String name;
  final String address;
  final double rating;
  LatLng? coordinates; // To be filled in by geocoding

  ParsedLocation({
    required this.name,
    required this.address,
    required this.rating,
    this.coordinates,
  });
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // --- Existing State Variables ---
  final TextEditingController _messageController = TextEditingController();
  WebSocketChannel? _channel;
  bool _isConnected = false;
  final List<ChatMessage> _messages = [];
  StreamSubscription? _streamSubscription;
  final ScrollController _scrollController = ScrollController();
  Timer? _reconnectTimer;
  int _retryCount = 0;
  static const int _maxRetries = 5;
  static const double _initialReconnectDelay = 2.0;

  // --- NEW State Variables for the Map ---
  bool _showMapToggle = false;
  bool _isMapVisible = false;
  final Set<Marker> _markers = {};
  GoogleMapController? _mapController;
  Position? _currentUserPosition;
  final Completer<GoogleMapController> _mapCompleter = Completer();

  @override
  void initState() {
    super.initState(); // super.initState() should be called first.
    _initializeWebSocket();
    // NEW: Proactively request location permission on startup for a better user experience.
    _requestLocationOnStartup();
    // The dispose calls were moved to the dispose() method where they belong.
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _streamSubscription?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    _mapController?.dispose(); // Dispose the map controller.
    super.dispose();
  }

  void _scheduleReconnect() {
    if (_retryCount >= _maxRetries || !mounted) return;
    _reconnectTimer?.cancel();
    final delay = Duration(seconds: (pow(2, _retryCount) * _initialReconnectDelay).toInt());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connection lost. Retrying in ${delay.inSeconds} seconds...')),
      );
    }
    _reconnectTimer = Timer(delay, _initializeWebSocket);
    if (mounted) setState(() => _retryCount++);
  }

  Future<void> _initializeWebSocket() async {
    _reconnectTimer?.cancel();
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      // Handle unauthenticated user
      return;
    }

    try {
      final idToken = await user.getIdToken(true);
      final uri = Uri.parse('wss://app.galactic-streamhub.com/ws?token=$idToken');
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;

      if (mounted) {
        setState(() {
          _isConnected = true;
          _retryCount = 0;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Connected to the void!')),
        );
      }
      _streamSubscription?.cancel();
      // --- MODIFIED: Use the new listener function ---
      _listenToWebSocket();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to connect to chat: $e')),
        );
        setState(() => _isConnected = false);
        _scheduleReconnect();
      }
    }
  }

  // --- MODIFIED WebSocket Listener to parse messages ---
  void _listenToWebSocket() {
    _streamSubscription = _channel!.stream.listen(
      (message) {
        if (!mounted) return;

        String content;
        bool isFinalChunk = false;
        try {
          final decodedMessage = json.decode(message as String) as Map<String, dynamic>;
          if (decodedMessage.containsKey('turn_complete')) {
            isFinalChunk = true;
          }
          content = decodedMessage['data'] as String? ?? '';
        } catch (e) {
          content = message as String;
        }

        if (content.isEmpty && !isFinalChunk) return;

        setState(() {
          if (_messages.isNotEmpty && _messages.last.sender == Sender.server) {
            _messages.last.text += content;
          } else {
            _messages.add(ChatMessage(text: content, sender: Sender.server));
          }

          // When the server signals the end of its turn, check the complete message for locations.
          if (isFinalChunk) {
            final lastMessage = _messages.last; // The ChatMessage object
            final rawMessageText = lastMessage.text;
            print("--- 🕵️ DEBUG: Final chunk received. Analyzing message... ---");
            print("--- LAST MESSAGE: ---\n$rawMessageText\n--------------------");

          // --- FIX STARTS HERE ---
          // 1. Create a sanitized string for JSON parsing.
          // This function removes the common markdown fences ```json ... ```
          // as well as any leading/trailing whitespace.
          String sanitizedJsonString = rawMessageText
              .replaceAll('```json', '')
              .replaceAll('```', '')
              .trim();

          // 2. Try to parse the SANITIZED string.
          try {
            final decodedData = json.decode(sanitizedJsonString) as Map<String, dynamic>;
            final spokenResponse = decodedData['spoken_response'] as String?;
            final mapData = decodedData['map_data'] as List<dynamic>?;

            if (spokenResponse != null && mapData != null) {
              print("--- ✅ DEBUG: Parsed structured JSON response with spoken_response and map_data. ---");
              // Update the chat bubble to only show the conversational text
              lastMessage.text = spokenResponse;

              final locations = mapData.map((item) {
                return ParsedLocation(
                  name: item['name'] as String? ?? 'Unknown Name',
                  address: item['address'] as String? ?? 'No address provided',
                  rating: (item['rating'] as num?)?.toDouble() ?? 0.0,
                );
              }).toList();

              if (locations.isNotEmpty) {
                setState(() => _showMapToggle = true);
                _handleLocationResponse(locations);
              }
            } else {
              // The JSON was valid but didn't have our expected map keys.
              // Fallback to text parsing for other potential data formats.
              _fallbackToTextParsing(rawMessageText);
            }
          } catch (e) {
            // 3. If parsing the sanitized string STILL fails, it's not the JSON
            // format we're looking for. Fall back to the original text parsing logic.
            print("--- ⚠️ DEBUG: Failed to parse as structured JSON. Falling back to text parsing. Error: $e ---");
            _fallbackToTextParsing(rawMessageText);
          }
          // --- FIX ENDS HERE ---
        }
      });
      _scrollToBottom();
    },
      onError: (error) {
        if (mounted) {
          if (_isConnected) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Disconnected from chat server.')));
          }
          setState(() => _isConnected = false);
          _scheduleReconnect();
        }
      },
      onDone: () {
        if (mounted) {
          if (_isConnected) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Disconnected from chat server.')));
          }
          setState(() => _isConnected = false);
          _scheduleReconnect();
        }
      },
      cancelOnError: true,
    );
  }

  void _fallbackToTextParsing(String messageText) {
    final locations = _parseLocationsFromText(messageText);
    if (locations.isNotEmpty) {
      print("--- ✅ DEBUG: Found ${locations.length} locations via text parsing. Showing map toggle. ---");
      setState(() => _showMapToggle = true);
      _handleLocationResponse(locations);
    }
}

  void _sendMessage() {
    if (_messageController.text.isNotEmpty && _channel != null && _isConnected) {
      final messageText = _messageController.text;

      // NEW: Construct a richer JSON payload with location data, if available.
      // This implements your suggestion to send context to the server.
      final payload = <String, dynamic>{
        'mime_type': 'text/plain',
        'data': messageText,
      };

      // If we have the user's location, add it to the payload.
      // The backend can use this for more accurate, context-aware responses.
      if (_currentUserPosition != null) {
        payload['lat'] = _currentUserPosition!.latitude;
        payload['lon'] = _currentUserPosition!.longitude;
      }

      final messageJson = json.encode(payload);
      _channel!.sink.add(messageJson);
      setState(() {
        _messages.add(ChatMessage(text: messageText, sender: Sender.user));
        // Reset map state for new query
        _isMapVisible = false;
        _showMapToggle = false;
        _markers.clear();
      });
      _scrollToBottom();
      _messageController.clear();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // --- NEW: Function to parse the server's text response and build the map ---
  Future<void> _handleLocationResponse(List<ParsedLocation> locations) async {
    // 1. Ensure we have the most up-to-date user location for the "You are here" marker.
    await _getCurrentUserLocation();
    if (_currentUserPosition == null || !mounted) {
      // If we can't get the location, we can't show the map.
      print("--- ❌ User location not available. Aborting map creation. ---");
      return;
    }

    // 2. The locations are already parsed and passed in.
    print("--- 🕵️ Handling ${locations.length} pre-parsed locations. ---");
    if (locations.isEmpty) return;

    // 3. Geocode addresses and create markers.
    final newMarkers = <Marker>{};

    // Add marker for the user's current location.
    newMarkers.add(Marker(
      markerId: const MarkerId('user_location'),
      position: LatLng(_currentUserPosition!.latitude, _currentUserPosition!.longitude),
      infoWindow: const InfoWindow(title: 'Your Location'),
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
    ));

    // Geocode all addresses in parallel for better performance.
    final geocodingFutures = locations.map((loc) async {
      try {
        final geoResult = await locationFromAddress(loc.address);
        if (geoResult.isNotEmpty) {
          final coordinates = LatLng(geoResult.first.latitude, geoResult.first.longitude);
          return Marker(
            markerId: MarkerId(loc.name),
            position: coordinates,
            infoWindow: InfoWindow(title: loc.name, snippet: 'Rating: ${loc.rating} stars'),
          );
        }
      } catch (e) {
        print("Geocoding failed for ${loc.address}: $e");
      }
      return null;
    });

    final geocodedMarkers = await Future.wait(geocodingFutures);
    newMarkers.addAll(geocodedMarkers.whereType<Marker>());

    // 4. Update the UI state with the new markers.
    setState(() {
      _markers.clear();
      _markers.addAll(newMarkers);
    });

    // 5. Animate camera to fit all markers, but only if the map is visible.
    if (_isMapVisible) {
      _animateCameraToFitMarkers();
    }
  }

  // --- NEW: Helper function to extract locations using Regex ---
  List<ParsedLocation> _parseLocationsFromText(String text) {
    final List<ParsedLocation> foundLocations = [];

    // Pattern 1: The original structured format with name, address, and rating.
    final RegExp exp1 = RegExp(
      r'\*\*(.*?):\*\* Located at (.*?)\. It has a rating of ([\d.]+?) stars',
      multiLine: true,
    );
    exp1.allMatches(text).forEach((match) {
      foundLocations.add(ParsedLocation(
        name: match.group(1)!.trim(),
        address: match.group(2)!.trim(),
        rating: double.tryParse(match.group(3) ?? '0') ?? 0,
      ));
    });

    // Pattern 2: The new conversational format observed in the logs.
    // e.g., "The closest seems to be [NAME] at [ADDRESS]."
    final RegExp exp2 = RegExp(
      r'([Tt]he closest seems to be|Here is|Another option is) (.*?) at (.*?)\.',
      multiLine: true,
    );
    exp2.allMatches(text).forEach((match) {
      // Use group 3 for the address, as group 1 is the conversational intro.
      final address = match.group(3)!.trim();
      // Check if this location was already found by a more specific regex to avoid duplicates.
      if (!foundLocations.any((loc) => loc.address == address)) {
        foundLocations.add(ParsedLocation(
          name: match.group(2)!.trim(),
          address: address,
          rating: 0, // No rating info is available in this format.
        ));
      }
    });

    // NEW Pattern 3: The bulleted list format seen in the latest logs.
    // e.g., "*   Naija Liquor: 66 Adeniyi Jones, Ikeja, Lagos. Rating: 5.0"
    final RegExp exp3 = RegExp(
      r'^\s*\*\s*(.*?):\s*(.*?)\.\s*Rating:\s*([\d.]+)',
      multiLine: true,
    );
    exp3.allMatches(text).forEach((match) {
      final address = match.group(2)!.trim();
      // Avoid duplicates if already parsed by a more specific regex
      if (!foundLocations.any((loc) => loc.address == address)) {
        foundLocations.add(ParsedLocation(
          name: match.group(1)!.trim(),
          address: address,
          rating: double.tryParse(match.group(3) ?? '0') ?? 0,
        ));
      }
    });
    return foundLocations;
  }

  // --- NEW: Function to get user's location with permissions ---
  Future<void> _getCurrentUserLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location services are disabled.')));
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location permissions are denied.')));
        return;
      }
    }

    if (permission == LocationPermission.deniedForever && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location permissions are permanently denied.')));
      return;
    }

    _currentUserPosition = await Geolocator.getCurrentPosition();
    setState(() {});
  }

  // --- NEW: Function to handle initial location permission on app startup ---
  Future<void> _requestLocationOnStartup() async {
    // This function handles the permission dialog at the beginning
    // so the user isn't surprised later.
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enable location services for location-based features.')));
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
  }

  // --- NEW: Function to animate map camera to fit all markers ---
  void _animateCameraToFitMarkers() async {
    if (_markers.isEmpty) return;

    final GoogleMapController controller = await _mapCompleter.future;

    LatLngBounds bounds;
    if (_markers.length == 1) {
      bounds = LatLngBounds(southwest: _markers.first.position, northeast: _markers.first.position);
    } else {
      bounds = LatLngBounds(
        southwest: LatLng(
          _markers.map((m) => m.position.latitude).reduce(min),
          _markers.map((m) => m.position.longitude).reduce(min),
        ),
        northeast: LatLng(
          _markers.map((m) => m.position.latitude).reduce(max),
          _markers.map((m) => m.position.longitude).reduce(max),
        ),
      );
    }

    await controller.animateCamera(CameraUpdate.newLatLngBounds(bounds, 60.0)); // 60.0 is padding
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.person_outline, color: Colors.white70),
            tooltip: 'User Profile',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (context) => const ProfileScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.redAccent),
            tooltip: 'Sign Out',
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          _buildAnimatedBackground(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // --- Main content area ---
                  Container(
                    margin: const EdgeInsets.only(top: 16),
                    child: Lottie.asset(
                      'assets/rocket_launch.json',
                      width: 120,
                      height: 120,
                      fit: BoxFit.contain,
                    ),
                  ).animate().scale(duration: 800.ms, delay: 300.ms),
                  const Text(
                    'Welcome to the Cosmos!',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Colors.white70,
                      shadows: [
                        Shadow(blurRadius: 10.0, color: Colors.cyanAccent, offset: Offset(0, 0)),
                        Shadow(blurRadius: 20.0, color: Colors.blueAccent, offset: Offset(0, 0)),
                      ],
                    ),
                  ).animate().fadeIn(duration: 1000.ms, delay: 500.ms),
                  const SizedBox(height: 24),
                  Expanded(
                    child: _buildChatInterface(),
                  ),

                  // --- NEW: The Map View is inserted here ---
                  if (_showMapToggle) _buildMapView(),

                  _buildInputArea(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnimatedBackground() {
    return Positioned.fill(
      child: Opacity(
        opacity: 0.4,
        child: Lottie.asset(
          'assets/starfield.json',
          fit: BoxFit.cover,
          repeat: true,
          animate: true,
        ),
      ),
    );
  }

  Widget _buildChatInterface() {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 16.0),
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4),
        borderRadius: BorderRadius.circular(20.0),
        border: Border.all(color: Colors.white30, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.blue.withOpacity(0.2),
            blurRadius: 15.0,
            spreadRadius: 5.0,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Galactic Comms:',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.white70,
                ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _isConnected
                ? ListView.builder(
                    controller: _scrollController,
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      return _buildMessageBubble(message);
                    },
                  )
                : Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Lottie.asset('assets/nebulae.json', width: 150, height: 150),
                        const SizedBox(height: 16),
                        Text(
                          _retryCount > 0 ? 'Re-establishing connection... (Attempt $_retryCount/$_maxRetries)' : 'Establishing connection to the void...',
                          style: const TextStyle(color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    // ... This widget is unchanged ...
    final isUser = message.sender == Sender.user;
    final alignment = isUser ? Alignment.topRight : Alignment.topLeft;
    final color = isUser ? Colors.blue.withOpacity(0.7) : Colors.deepPurple.withOpacity(0.6);
    final textColor = Colors.white;
    final borderColor = isUser ? Colors.cyanAccent.withOpacity(0.5) : Colors.purpleAccent.withOpacity(0.5);

    return Align(
      alignment: alignment,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
        padding: const EdgeInsets.all(12.0),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(isUser ? 20.0 : 0.0),
            topRight: Radius.circular(isUser ? 0.0 : 20.0),
            bottomLeft: const Radius.circular(20.0),
            bottomRight: const Radius.circular(20.0),
          ),
          border: Border.all(color: borderColor, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: color.withOpacity(0.4),
              blurRadius: 10,
              spreadRadius: 2,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Text(
          message.text,
          style: TextStyle(color: textColor, fontSize: 16, height: 1.3),
        ),
      ),
    );
  }

  // --- NEW: Widget for the Map View ---
  Widget _buildMapView() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
      height: _isMapVisible ? MediaQuery.of(context).size.height * 0.4 : 0,
      margin: const EdgeInsets.only(bottom: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20.0),
        child: GoogleMap(
          onMapCreated: (GoogleMapController controller) {
            if (!_mapCompleter.isCompleted) {
              _mapCompleter.complete(controller);
            }
            _mapController = controller;
          },
          initialCameraPosition: CameraPosition(
            target: _currentUserPosition != null
                ? LatLng(_currentUserPosition!.latitude, _currentUserPosition!.longitude)
                : const LatLng(6.5244, 3.3792), // Default to Lagos, Nigeria
            zoom: 12,
          ),
          markers: _markers,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
        ),
      ),
    );
  }

  // --- MODIFIED: Input area now includes the map toggle button ---
  Widget _buildInputArea() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20.0),
      child: Row(
        children: [
          // Conditionally show the map toggle button with an animation.
          if (_showMapToggle)
            Animate(
              effects: const [FadeEffect(), ScaleEffect()],
              child: Container(
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.4),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.cyanAccent.withOpacity(0.4), width: 1.5),
                ),
                child: IconButton(
                  icon: Icon(_isMapVisible ? Icons.map : Icons.map_outlined, color: Colors.cyanAccent),
                  tooltip: _isMapVisible ? 'Hide Map' : 'Show Map',
                  onPressed: () {
                    setState(() {
                      _isMapVisible = !_isMapVisible;
                    });
                    // If we are showing the map, animate the camera to fit the markers.
                    if (_isMapVisible) {
                      // Small delay to allow the map to build before animating.
                      Future.delayed(const Duration(milliseconds: 100), _animateCameraToFitMarkers);
                    }
                  },
                ),
              ),
            ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.4),
                borderRadius: BorderRadius.circular(30.0),
                border: Border.all(color: Colors.cyanAccent.withOpacity(0.4), width: 1.5),
              ),
              child: TextField(
                controller: _messageController,
                style: const TextStyle(color: Colors.white70),
                cursorColor: Colors.cyanAccent,
                decoration: InputDecoration(
                  hintText: 'Communicate with the galaxy...',
                  hintStyle: const TextStyle(color: Colors.white54),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 12.0),
                  border: InputBorder.none,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.send_outlined, color: Colors.cyanAccent),
                    onPressed: _sendMessage,
                    tooltip: 'Send Message',
                  ),
                ),
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// --- Helper Classes (Unchanged) ---
enum Sender { user, server }

class ChatMessage {
  String text;
  final Sender sender;

  ChatMessage({required this.text, required this.sender});
}