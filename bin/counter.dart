// import 'package:iso_tools/iso_tools.dart';

import 'dart:async';
import 'dart:io';

import 'package:processors/processor.dart';

Future<Map<String, int>> countFile(List inputs) async {
  var filePath = inputs[0] as String;
  var startIndex = inputs[1] as int;
  var endIndex = inputs[2] as int;

  var count = <String, int>{};

  await for (var block in File(filePath).openRead(startIndex, endIndex)) {
    var str = String.fromCharCodes(block);

    for (var i = 0; i < str.length; i++) {
      if (count.containsKey(str[i])) {
        count[str[i]] = count[str[i]]! + 1;
      } else {
        count[str[i]] = 1;
      }
    }
  }

  return count;
}

Future<void> main(List<String> args) async {
  var st = DateTime.now();

  // var filePath = r'D:\Games\Chronos - Before the Ashes\Chronos\Content\Paks\Chronos-WindowsNoEditor.pak';
  // var filePath = r'D:\Games\Mass Effect - LE\Game\ME1\BioGame\CookedPCConsole\Lighting1.tfc';
  var filePath = './bin/counter.dart';

  var len = await File(filePath).length();

  var chunkSize = len ~/ 8;

  var pool = ProcessorPool(countFile);
  await pool.start();

  for (var i = 0; i < 8; i++) {
    var startIndex = i * chunkSize;
    var endIndex = i == 7 ? len : startIndex + chunkSize;

    pool.send([filePath, startIndex, endIndex]);
  }

  var count = 8;
  await for (var each in pool.outputStream) {
    print(each);
    if (--count == 0) break;
  }
  pool.shutdown();

  print(DateTime.now().difference(st));
}
