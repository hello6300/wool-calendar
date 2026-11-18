import 'package:flutter_test/flutter_test.dart';
import 'package:appforge_demo/main.dart';

void main() {
  group('Counter', () {
    test('starts at zero', () {
      expect(Counter().count, 0);
    });

    test('increments and notifies listeners', () {
      final counter = Counter();
      var notifications = 0;
      counter.addListener(() => notifications++);

      counter.inc();

      expect(counter.count, 1);
      expect(notifications, 1);
    });
  });
}
