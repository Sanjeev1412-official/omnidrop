class ChatMessage {
  final String text;
  final bool isMe;
  final DateTime timestamp;
  final String? fileName;
  final int? fileSize;
  final String? fileExtension;
  double transferProgress; // 0.0 to 1.0
  bool isTransferComplete;
  String? transferSpeed;

  ChatMessage({
    required this.text,
    required this.isMe,
    required this.timestamp,
    this.fileName,
    this.fileSize,
    this.fileExtension,
    this.transferProgress = 0.0,
    this.isTransferComplete = false,
    this.transferSpeed,
  });

  Map<String, dynamic> toJson() {
    return {
      'text': text,
      'isMe': isMe,
      'timestamp': timestamp.toIso8601String(),
      'fileName': fileName,
      'fileSize': fileSize,
      'fileExtension': fileExtension,
      'transferProgress': transferProgress,
      'isTransferComplete': isTransferComplete,
      'transferSpeed': transferSpeed,
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      text: json['text'] as String,
      isMe: json['isMe'] as bool,
      timestamp: DateTime.parse(json['timestamp'] as String),
      fileName: json['fileName'] as String?,
      fileSize: json['fileSize'] as int?,
      fileExtension: json['fileExtension'] as String?,
      transferProgress: (json['transferProgress'] as num?)?.toDouble() ?? 0.0,
      isTransferComplete: json['isTransferComplete'] as bool? ?? false,
      transferSpeed: json['transferSpeed'] as String?,
    );
  }
}
