# Fixed Berry script connection monitoring - PROPER JSON PARSING

import json

class ConnectionMonitor
  var last_successful_publish
  var heartbeat_timer
  var connection_status
  var publish_attempts
  var max_retries
  var data_buffer
  var start_time
  var mqtt_connected
  var last_mqtt_check
  
  def init()
    self.last_successful_publish = tasmota.millis()
    self.connection_status = "unknown"
    self.publish_attempts = 0
    self.max_retries = 3
    self.data_buffer = []
    self.start_time = tasmota.millis()
    self.mqtt_connected = false
    self.last_mqtt_check = 0
    
    # Heartbeat на всеки 30 секунди
    self.heartbeat_timer = tasmota.set_timer(30000, /-> self.send_heartbeat())
    print("Connection Monitor инициализиран с FIXED JSON parsing")
  end
  
  def get_uptime_seconds()
    return int((tasmota.millis() - self.start_time) / 1000)
  end
  
  def check_mqtt_status()
    # Проверява MQTT статуса чрез Status 6 команда с PROPER JSON parsing
    try
      var status_result = tasmota.cmd("Status 6")
      
      if status_result != nil
        # Berry автоматично парсира JSON отговора в map/dictionary
        if type(status_result) == 'instance' && status_result.contains('StatusMQT')
          var mqtt_status = status_result['StatusMQT']
          
          # Проверяваме дали MqttCount съществува и е > 0
          if mqtt_status.contains('MqttCount') && mqtt_status['MqttCount'] > 0
            self.mqtt_connected = true
            self.last_mqtt_check = tasmota.millis()
            print("MQTT Status: Connected (MqttCount: " + str(mqtt_status['MqttCount']) + ")")
            return true
          else
            print("MQTT Status: No active connections")
          end
        else
          print("MQTT Status: Invalid response format")
        end
      else
        print("MQTT Status: Command returned nil")
      end
      
    except .. as e
      print("MQTT status check exception: " + str(e))
    end
    
    self.mqtt_connected = false
    return false
  end
  
  # Alternative method using string parsing as fallback
  def check_mqtt_status_fallback()
    try
      var status_result = tasmota.cmd("Status 6")
      
      if status_result != nil
        var status_str = str(status_result)
        
        # Look for MqttCount with value > 0
        var mqtt_count_pos = status_str.find('"MqttCount":')
        if mqtt_count_pos != nil
          # Extract the number after MqttCount
          var start_pos = mqtt_count_pos + 12  # Length of "MqttCount":
          var end_pos = status_str.find(',', start_pos)
          if end_pos == nil
            end_pos = status_str.find('}', start_pos)
          end
          
          if end_pos != nil
            var count_str = status_str[start_pos..end_pos-1]
            var count_val = int(count_str)
            
            if count_val > 0
              self.mqtt_connected = true
              self.last_mqtt_check = tasmota.millis()
              print("MQTT Status (fallback): Connected (Count: " + str(count_val) + ")")
              return true
            end
          end
        end
        
        print("MQTT Status (fallback): No active connections")
      end
      
    except .. as e
      print("MQTT status fallback check failed: " + str(e))
    end
    
    self.mqtt_connected = false
    return false
  end
  
  # Primary method with fallback
  def check_mqtt_connection()
    # Try primary method first
    if self.check_mqtt_status()
      return true
    end
    
    # Fallback to string parsing
    print("Using fallback MQTT status check...")
    return self.check_mqtt_status_fallback()
  end
  
  def send_heartbeat()
    var uptime_sec = self.get_uptime_seconds()
    var heartbeat = '{"heartbeat":' + str(tasmota.millis()) + ',"uptime":' + str(uptime_sec) + '}'
    
    # Използваме FIXED MQTT status detection
    var mqtt_ok = self.check_mqtt_connection()
    
    # Винаги изпращаме heartbeat
    self.try_publish("v1/devices/me/telemetry", heartbeat)
    
    if mqtt_ok
      self.last_successful_publish = tasmota.millis()
      self.connection_status = "connected"
      self.publish_attempts = 0
      
      # Изпрати буфериран данни ако има такива
      self.flush_buffer()
      print("Heartbeat sent - MQTT connection CONFIRMED via Status check")
    else
      self.publish_attempts += 1
      if self.publish_attempts >= self.max_retries
        self.connection_status = "no connection"
        print("Connection lost - switching to offline mode")
      else
        self.connection_status = "not stable"
        print("Connection unstable - attempt " + str(self.publish_attempts))
      end
    end
    
    # Планиране на следващ heartbeat
    self.heartbeat_timer = tasmota.set_timer(30000, /-> self.send_heartbeat())
  end
  
  def try_publish(topic, payload)
    try
      var result = tasmota.cmd("Publish " + topic + " " + payload)
      print("Publish executed - result: " + str(result))
      return true
      
    except .. as e
      print("Publish failed - exception: " + str(e))
      return false
    end
  end
  
  def publish_or_buffer(topic, payload)
    # Винаги опитваме да публикуваме
    self.try_publish(topic, payload)
    
    # Connection detection базиран на FIXED MQTT status check
    var current_time = tasmota.millis()
    
    # Проверяваме MQTT статуса не по-често от на всеки 5 секунди
    if (current_time - self.last_mqtt_check) > 5000
      var mqtt_ok = self.check_mqtt_connection()
      
      if mqtt_ok
        self.last_successful_publish = current_time
        self.connection_status = "connected"
        self.publish_attempts = 0
        return true
      else
        # Буфериране при MQTT проблеми
        var buffered_data = {
          "timestamp": current_time,
          "topic": topic,
          "payload": payload
        }
        
        self.data_buffer.push(buffered_data)
        
        # Ограничаване на буфера (последните 100 записа)
        if size(self.data_buffer) > 100
          self.data_buffer.remove(0)
        end
        
        self.connection_status = "offline"
        print("Data buffered - MQTT check failed")
        return false
      end
    else
      # Използваме последния известен статус
      if self.connection_status == "connected"
        return true
      else
        # Буфериране
        var buffered_data = {
          "timestamp": current_time,
          "topic": topic,
          "payload": payload
        }
        
        self.data_buffer.push(buffered_data)
        if size(self.data_buffer) > 100
          self.data_buffer.remove(0)
        end
        
        print("Data buffered - using cached connection status")
        return false
      end
    end
  end
  
  def flush_buffer()
    if size(self.data_buffer) > 0
      print("Flushing " + str(size(self.data_buffer)) + " buffered records")
      
      var mqtt_ok = self.check_mqtt_connection()
      
      if mqtt_ok
        var sent_count = 0
        var max_flush = 10  # Максимум 10 на веднъж
        
        while size(self.data_buffer) > 0 && sent_count < max_flush
          var record = self.data_buffer[0]
          self.try_publish(record["topic"], record["payload"])
          self.data_buffer.remove(0)
          sent_count += 1
        end
        
        print("Successfully flushed " + str(sent_count) + " buffered records")
        
        if size(self.data_buffer) > 0
          print("Remaining in buffer: " + str(size(self.data_buffer)) + " records")
        end
      else
        print("Cannot flush buffer - MQTT check failed")
      end
    end
  end
  
  def get_connection_status()
    return self.connection_status
  end
  
  def get_buffer_size()
    return size(self.data_buffer)
  end
  
  def get_mqtt_status()
    return self.mqtt_connected
  end
  
  # Ръчно потвърждаване на връзката
  def confirm_connection()
    self.mqtt_connected = true
    self.last_successful_publish = tasmota.millis()
    self.connection_status = "connected"
    self.publish_attempts = 0
    self.last_mqtt_check = tasmota.millis()
    print("Connection manually confirmed as working")
  end
  
  # Debug method to inspect Status 6 response
  def debug_status_response()
    try
      var status_result = tasmota.cmd("Status 6")
      print("=== DEBUG STATUS 6 ===")
      print("Type: " + type(status_result))
      print("Value: " + str(status_result))
      
      if status_result != nil && type(status_result) == 'instance'
        print("Keys available:")
        for key: status_result.keys()
          print("  " + str(key))
        end
        
        if status_result.contains('StatusMQT')
          var mqtt_info = status_result['StatusMQT']
          print("StatusMQT keys:")
          for key: mqtt_info.keys()
            print("  " + str(key) + " = " + str(mqtt_info[key]))
          end
        end
      end
      print("=== END DEBUG ===")
      
    except .. as e
      print("Debug failed: " + str(e))
    end
  end
end

class ModbusReader
  var timer_id
  var last_read_time
  var sensor_timeout
  var connection_monitor
  
  def init(conn_monitor)
    self.connection_monitor = conn_monitor
    self.last_read_time = 0
    self.sensor_timeout = 120000
    
    self.timer_id = tasmota.set_timer(60000, /-> self.read_modbus())
    tasmota.set_timer(150000, /-> self.check_if_no_data())
    
    print("Modbus Reader инициализиран с improved connection monitoring")
  end
  
  def read_modbus()
    var cmd = '{"deviceaddress":1,"functioncode":3,"startaddress":0,"type":"int16","count":2}'
    tasmota.cmd("ModbusSend " + cmd)
    self.timer_id = tasmota.set_timer(60000, /-> self.read_modbus())
  end
  
  def modbus_received(values)
    if size(values) >= 2
      var humidity = values[0] * 0.1
      var temperature = values[1] * 0.1
      self.last_read_time = tasmota.millis()
      
      # Telemetry с timestamp
      var payload = '{"humidity":' + str(humidity) + ',"temperature":' + str(temperature) + 
                   ',"timestamp":' + str(tasmota.millis()) + '}'
      
      var success = self.connection_monitor.publish_or_buffer("v1/devices/me/telemetry", payload)
      
      if success
        self.check_and_publish_statuses()
        print("Публикувани данни: H=" + str(humidity) + ", T=" + str(temperature))
      else
        print("Данни буферирани: H=" + str(humidity) + ", T=" + str(temperature))
      end
    end
  end
  
  def check_and_publish_statuses()
    var conn_status = self.connection_monitor.get_connection_status()
    var buffer_size = self.connection_monitor.get_buffer_size()
    var mqtt_status = self.connection_monitor.get_mqtt_status()
    
    var status_payload = '{"sensor_status":"available","connection_status":"' + 
                        conn_status + '","buffer_size":' + str(buffer_size) + 
                        ',"mqtt_connected":' + str(mqtt_status) + '}'
    
    self.connection_monitor.publish_or_buffer("v1/devices/me/attributes", status_payload)
  end
  
  def check_if_no_data()
    var current_time = tasmota.millis()
    
    if self.last_read_time == 0 || (current_time - self.last_read_time) > self.sensor_timeout
      var conn_status = self.connection_monitor.get_connection_status()
      var buffer_size = self.connection_monitor.get_buffer_size()
      
      var status_payload = '{"sensor_status":"not responding","connection_status":"' + 
                          conn_status + '","buffer_size":' + str(buffer_size) + '}'
      
      self.connection_monitor.publish_or_buffer("v1/devices/me/attributes", status_payload)
      print("Sensor not responding - status updated")
    end
    
    tasmota.set_timer(150000, /-> self.check_if_no_data())
  end
end

class RelayController
  var relay_states
  var connection_monitor
  
  def init(conn_monitor)
    self.connection_monitor = conn_monitor
    self.relay_states = {}
    
    for i: 1..8
      self.relay_states[i] = 0
    end
    
    print("Relay Controller стартиран с improved connection monitoring")
    self.sync_states()
  end
  
  def sync_states()
    print("=== Синхронизиране ===")
    for i: 1..8
      var power_num = 9 - i
      var power_state = tasmota.get_power()
      var current_state = 0
      
      if power_state && size(power_state) >= power_num
        current_state = power_state[power_num-1] ? 1 : 0
      end
      
      self.relay_states[i] = current_state
      print("Реле " + str(i) + " [Power" + str(power_num) + "]: " + str(current_state))
    end
    
    self.publish_all_states()
  end
  
  def publish_all_states()
    var attributes = "{"
    for i: 1..8
      if i > 1
        attributes += ","
      end
      attributes += '"relay' + str(i) + '":' + str(self.relay_states[i])
    end
    
    # Добавяне на connection info
    var conn_status = self.connection_monitor.get_connection_status()
    var buffer_size = self.connection_monitor.get_buffer_size()
    var mqtt_status = self.connection_monitor.get_mqtt_status()
    
    attributes += ',"connection_status":"' + conn_status + '"'
    attributes += ',"buffer_size":' + str(buffer_size)
    attributes += ',"mqtt_connected":' + str(mqtt_status)
    attributes += ',"last_update":' + str(tasmota.millis())
    attributes += "}"
    
    var success = self.connection_monitor.publish_or_buffer("v1/devices/me/attributes", attributes)
    
    if success
      print("Публикувани client attributes")
    else
      print("Client attributes буферирани")
    end
  end
  
  def set_relay(physical_relay, state)
    if physical_relay < 1 || physical_relay > 8
      return 0
    end
    
    var power_num = 9 - physical_relay
    var new_state = state ? 1 : 0
    
    if self.relay_states[physical_relay] != new_state
      self.relay_states[physical_relay] = new_state
      var cmd = "Power" + str(power_num) + " " + str(new_state)
      tasmota.cmd(cmd)
      
      print("Реле " + str(physical_relay) + " [Power" + str(power_num) + "]: " + str(new_state))
      
      # Публикуване с timestamp
      var status = '{"relay' + str(physical_relay) + '":' + str(new_state) + 
                  ',"timestamp":' + str(tasmota.millis()) + '}'
      
      var success = self.connection_monitor.publish_or_buffer("v1/devices/me/attributes", status)
      
      if !success
        print("Relay state change buffered")
      end
      
      return 1
    end
    return 0
  end
  
  def handle_power_change(power_num, state)
    var physical_relay = 9 - power_num
    var new_state = state ? 1 : 0
    
    if physical_relay >= 1 && physical_relay <= 8
      self.relay_states[physical_relay] = new_state
      print("Промяна: Power" + str(power_num) + " -> Реле " + str(physical_relay) + ": " + str(new_state))
      
      var status = '{"relay' + str(physical_relay) + '":' + str(new_state) + 
                  ',"timestamp":' + str(tasmota.millis()) + '}'
      
      self.connection_monitor.publish_or_buffer("v1/devices/me/attributes", status)
    end
  end
  
  def toggle_relay(physical_relay)
    var current_state = self.relay_states[physical_relay]
    return self.set_relay(physical_relay, current_state == 0)
  end
  
  def all_on()
    for i: 1..8
      self.set_relay(i, 1)
    end
  end
  
  def all_off()
    for i: 1..8
      self.set_relay(i, 0)
    end
  end
  
  def get_status()
    print("=== Статус ===")
    for i: 1..8
      var state = self.relay_states[i]
      var power_num = 9 - i
      print("Реле " + str(i) + " [Power" + str(power_num) + "]: " + str(state))
    end
    return self.relay_states
  end
end

# MQTT Event Monitoring за автоматично detection на състоянието
class MQTTEventMonitor
  var connection_monitor
  
  def init(conn_monitor)
    self.connection_monitor = conn_monitor
    
    # Monitor MQTT connect/disconnect events
    tasmota.add_rule("Mqtt#Connected", def (value, trigger)
      print("MQTT Connected event detected")
      self.connection_monitor.confirm_connection()
    end)
    
    tasmota.add_rule("Mqtt#Disconnected", def (value, trigger)
      print("MQTT Disconnected event detected")
      # Mark connection as problematic but don't immediately buffer
      # Let the heartbeat system handle the detection
    end)
    
    print("MQTT Event Monitor активиран")
  end
end

# Инициализация с improved connection monitoring
var connection_monitor = ConnectionMonitor()
var modbus_reader = ModbusReader(connection_monitor)
var relay_controller = RelayController(connection_monitor)
var mqtt_monitor = MQTTEventMonitor(connection_monitor)

# Event handlers
tasmota.add_rule("ModbusReceived#Values", def (value, trigger) 
  modbus_reader.modbus_received(value)
end)

# Power state monitoring
tasmota.add_rule("Power1#state", def (value, trigger)
  relay_controller.handle_power_change(1, value == 1)
end)

tasmota.add_rule("Power2#state", def (value, trigger)
  relay_controller.handle_power_change(2, value == 1)
end)

tasmota.add_rule("Power3#state", def (value, trigger)
  relay_controller.handle_power_change(3, value == 1)
end)

tasmota.add_rule("Power4#state", def (value, trigger)
  relay_controller.handle_power_change(4, value == 1)
end)

tasmota.add_rule("Power5#state", def (value, trigger)
  relay_controller.handle_power_change(5, value == 1)
end)

tasmota.add_rule("Power6#state", def (value, trigger)
  relay_controller.handle_power_change(6, value == 1)
end)

tasmota.add_rule("Power7#state", def (value, trigger)
  relay_controller.handle_power_change(7, value == 1)
end)

tasmota.add_rule("Power8#state", def (value, trigger)
  relay_controller.handle_power_change(8, value == 1)
end)

# Enhanced console commands
tasmota.add_cmd("relay_sync", def()
  relay_controller.sync_states()
end)

tasmota.add_cmd("relay_status", def()
  relay_controller.get_status()
end)

tasmota.add_cmd("connection_status", def()
  var status = connection_monitor.get_connection_status()
  var buffer_size = connection_monitor.get_buffer_size()
  var mqtt_status = connection_monitor.get_mqtt_status()
  print("Connection: " + status + ", MQTT: " + str(mqtt_status) + ", Buffer: " + str(buffer_size) + " records")
end)

tasmota.add_cmd("flush_buffer", def()
  connection_monitor.flush_buffer()
end)

tasmota.add_cmd("force_heartbeat", def()
  connection_monitor.send_heartbeat()
end)

tasmota.add_cmd("confirm_connection", def()
  connection_monitor.confirm_connection()
end)

tasmota.add_cmd("mqtt_check", def()
  var mqtt_ok = connection_monitor.check_mqtt_connection()
  print("MQTT Status Check: " + str(mqtt_ok))
end)

# Test commands for debugging (after connection_monitor is created)
tasmota.add_cmd("debug_status", def()
  connection_monitor.debug_status_response()
end)

tasmota.add_cmd("test_mqtt_check", def()
  var result = connection_monitor.check_mqtt_connection()
  print("MQTT Check Result: " + str(result))
end)
tasmota.add_cmd("relay_all_on", def()
  relay_controller.all_on()
  print("Всички релета включени")
end)

tasmota.add_cmd("relay_all_off", def()
  relay_controller.all_off()
  print("Всички релета изключени")
end)

# Също така можете да добавите глобални функции за по-лесна употреба:
def relay_all_on()
  relay_controller.all_on()
end

def relay_all_off()
  relay_controller.all_off()
end

# Глобални функции
def relay_on(num)
  relay_controller.set_relay(num, 1)
end

def relay_off(num)
  relay_controller.set_relay(num, 0)
end

def relay_toggle(num)
  relay_controller.toggle_relay(num)
end

def relay_set(num, state)
  relay_controller.set_relay(num, state)
end

print("=== FIXED CONNECTION MONITOR ===")
print("Improvements:")
print("  • Proper JSON parsing of Status 6 response")
print("  • Fallback string parsing method")
print("  • Better error handling and debugging")
print("  • More robust MQTT status detection")
print("New debug commands:")
print("  debug_status     - inspect Status 6 response structure")
print("  test_mqtt_check  - test MQTT connection detection")