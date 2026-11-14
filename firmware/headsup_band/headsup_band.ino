#include "config.h"

// M0 bring-up only: leave both motor/LED channels off. BLE, patterns,
// acknowledgements and watchdog behavior are implemented and verified in M2.
void setup() {
  pinMode(Config::leftMotorPin, OUTPUT);
  digitalWrite(Config::leftMotorPin, LOW);
  pinMode(Config::rightMotorPin, OUTPUT);
  digitalWrite(Config::rightMotorPin, LOW);
  pinMode(Config::buttonPin, INPUT_PULLUP);
}

void loop() {}
