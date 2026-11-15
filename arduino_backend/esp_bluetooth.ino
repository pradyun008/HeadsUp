#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

const int RIGHT = D10;
const int LEFT  = D4;

#define SERVICE_UUID "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define CHAR_UUID    "6e400002-b5a3-f393-e0a9-e50e24dcca9e"

struct Side {
  int pin;
  int level;
  unsigned long onMs, coolMs, endAt, phaseEnd;
  bool on, active;
};

Side left  = {LEFT,  0, 0, 0, 0, 0, false, false};
Side right = {RIGHT, 0, 0, 0, 0, 0, false, false};

void stopSide(Side &s) {
  analogWrite(s.pin, 0);
  s.active = false;
  s.on = false;
}

void startSide(Side &s, int level, unsigned long onMs, unsigned long coolMs, unsigned long totalMs) {
  level = constrain(level, 0, 255);
  if (level == 0) { stopSide(s); return; }
  if (onMs == 0) onMs = 500;
  if (onMs > 5000) onMs = 5000;
  if (coolMs > 5000) coolMs = 5000;
  if (totalMs > 60000) totalMs = 60000;

  unsigned long now = millis();
  s.level = level;
  s.onMs = onMs;
  s.coolMs = coolMs;
  s.on = true;
  s.active = true;
  s.phaseEnd = now + onMs;
  s.endAt = (coolMs == 0 || totalMs == 0) ? now + onMs : now + totalMs;
  analogWrite(s.pin, level);
}

void updateSide(Side &s) {
  if (!s.active) return;
  unsigned long now = millis();
  if (now >= s.endAt) { stopSide(s); return; }
  if (now >= s.phaseEnd) {
    if (s.on) {
      analogWrite(s.pin, 0);
      s.on = false;
      s.phaseEnd = now + s.coolMs;
    } else {
      analogWrite(s.pin, s.level);
      s.on = true;
      s.phaseEnd = now + s.onMs;
    }
  }
}

void command(char side, int level, unsigned long onMs, unsigned long coolMs, unsigned long totalMs) {
  Serial.printf("Cmd %c level %d on %lu cool %lu total %lu\n", side, level, onMs, coolMs, totalMs);
  if (side == 'L') startSide(left, level, onMs, coolMs, totalMs);
  if (side == 'R') startSide(right, level, onMs, coolMs, totalMs);
}

class BuzzCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) override {
    uint8_t *d = c->getData();
    size_t n = c->getLength();
    if (n == 0) return;

    // Text: "R,level,on,cooldown,total" in ms, e.g. "R,200,300,200,3000"
    if (d[0] == 'L' || d[0] == 'R' || d[0] == 'l' || d[0] == 'r') {
      char buf[48];
      size_t len = n < sizeof(buf) - 1 ? n : sizeof(buf) - 1;
      memcpy(buf, d, len);
      buf[len] = 0;
      char side = toupper(buf[0]);
      int level = 200;
      unsigned long onMs = 500, coolMs = 0, totalMs = 0;
      if (buf[1] == ',') {
        sscanf(buf + 2, "%d,%lu,%lu,%lu", &level, &onMs, &coolMs, &totalMs);
      }
      command(side, level, onMs, coolMs, totalMs);
      return;
    }

    // Binary: [side 0/1][level][on ×100ms] and optional [cooldown ×100ms][total ×100ms]
    if (n >= 3) {
      char side = d[0] == 0 ? 'L' : 'R';
      unsigned long coolMs = n >= 5 ? d[3] * 100UL : 0;
      unsigned long totalMs = n >= 5 ? d[4] * 100UL : 0;
      command(side, d[1], d[2] * 100UL, coolMs, totalMs);
    }
  }
};

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *s) override { Serial.println("Connected"); }
  void onDisconnect(BLEServer *s) override {
    Serial.println("Disconnected, advertising again");
    BLEDevice::startAdvertising();
  }
};

void startupBuzz() {
  const int GENTLE = 120;
  analogWrite(LEFT, GENTLE);  delay(300);  analogWrite(LEFT, 0);  delay(300);
  analogWrite(RIGHT, GENTLE); delay(300);  analogWrite(RIGHT, 0);
}

void setup() {
  Serial.begin(115200);
  pinMode(RIGHT, OUTPUT);
  pinMode(LEFT, OUTPUT);
  digitalWrite(RIGHT, LOW);
  digitalWrite(LEFT, LOW);

  BLEDevice::init("HeadsUp");
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  BLEService *service = server->createService(SERVICE_UUID);
  BLECharacteristic *ch = service->createCharacteristic(
    CHAR_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  ch->setCallbacks(new BuzzCallbacks());
  service->start();
  BLEAdvertising *adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->start();
  Serial.println("Advertising as HeadsUp");
  startupBuzz();
}

void loop() {
  updateSide(left);
  updateSide(right);
}
