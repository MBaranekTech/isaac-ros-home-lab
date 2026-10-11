# Task 02: Build a ROS 2 Temperature Publisher

[← Back to the Isaac ROS Home Lab roadmap](README.md)

In this lab, you will create your first custom ROS 2 Python node. The node simulates a home-lab server temperature and publishes it once per second.

## What you will learn

- how a ROS 2 Python package is structured;
- how to create a custom node with `rclpy`;
- how to create a publisher and timer;
- how to use the `std_msgs/msg/Float32` message type;
- how to build a package with `colcon`;
- why a newly built workspace must be sourced;
- how to inspect published data from another terminal.

## Architecture

```mermaid
flowchart LR
    P["temperature_publisher<br/>Python node"]
    T["/homelab/temperature<br/>std_msgs/msg/Float32"]
    E["ros2 topic echo<br/>temporary subscriber"]

    P -->|"temperature in °C"| T
    T --> E
```

## Prerequisite

Task 01 must be complete and the `homelab_monitor` package must exist at:

```text
/workspaces/isaac_ros-dev/src/homelab_monitor
```

If necessary, create it inside the Isaac ROS container:

```bash
cd /workspaces/isaac_ros-dev/src

ros2 pkg create homelab_monitor \
  --build-type ament_python \
  --dependencies rclpy std_msgs \
  --license Apache-2.0
```

## 1. Create the publisher node

Open the source file inside the Isaac ROS container:

```bash
nano /workspaces/isaac_ros-dev/src/homelab_monitor/homelab_monitor/temperature_publisher.py
```

Add the following code:

```python
import math

import rclpy
from rclpy.node import Node
from std_msgs.msg import Float32


class TemperaturePublisher(Node):

    def __init__(self):
        super().__init__('temperature_publisher')

        self.publisher = self.create_publisher(
            Float32,
            '/homelab/temperature',
            10,
        )

        self.sample = 0
        self.timer = self.create_timer(1.0, self.publish_temperature)

        self.get_logger().info('Temperature publisher started')

    def publish_temperature(self):
        temperature = 55.0 + 20.0 * math.sin(self.sample / 5.0)

        message = Float32()
        message.data = float(temperature)

        self.publisher.publish(message)
        self.get_logger().info(
            f'Published temperature: {temperature:.1f} °C'
        )

        self.sample += 1


def main(args=None):
    rclpy.init(args=args)

    node = TemperaturePublisher()

    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
```

In Nano, save with `Ctrl+O`, confirm with Enter, and close with `Ctrl+X`.

The simulated temperature follows a smooth curve between approximately 35 °C and 75 °C. This will allow a monitoring node in the next task to test a 70 °C warning threshold.

## 2. Register the executable

Open the package configuration:

```bash
nano /workspaces/isaac_ros-dev/src/homelab_monitor/setup.py
```

Find this section:

```python
entry_points={
    'console_scripts': [
    ],
},
```

Replace it with:

```python
entry_points={
    'console_scripts': [
        'temperature_publisher = homelab_monitor.temperature_publisher:main',
    ],
},
```

This entry point maps the ROS 2 executable name `temperature_publisher` to the Python `main()` function.

## 3. Build the package

Build from the workspace root:

```bash
cd /workspaces/isaac_ros-dev

colcon build \
  --symlink-install \
  --packages-select homelab_monitor
```

Load the newly built overlay into the current shell:

```bash
source install/setup.bash
```

The `source` command is required in every new terminal that needs to use packages from this workspace.

## 4. Run the publisher

```bash
ros2 run homelab_monitor temperature_publisher
```

Expected output:

```text
Temperature publisher started
Published temperature: 55.0 °C
Published temperature: 59.0 °C
Published temperature: 62.8 °C
```

The node continues running until it is stopped with `Ctrl+C`.

## 5. Inspect the topic

Open a second SSH terminal and attach to the running Isaac ROS container:

```bash
isaac-ros activate
source /workspaces/isaac_ros-dev/install/setup.bash
```

Listen to the temperature topic:

```bash
ros2 topic echo --no-daemon /homelab/temperature
```

Expected output:

```yaml
data: 55.0
---
data: 58.973384857177734
---
```

Inspect the topic metadata:

```bash
ros2 topic type /homelab/temperature
ros2 topic info --no-daemon /homelab/temperature
ros2 interface show std_msgs/msg/Float32
```

Expected message type:

```text
std_msgs/msg/Float32
```

## Code walkthrough

### `Node`

```python
class TemperaturePublisher(Node):
```

The class inherits from the ROS 2 `Node` class. A node is an independently running participant in the ROS graph.

### Publisher

```python
self.publisher = self.create_publisher(
    Float32,
    '/homelab/temperature',
    10,
)
```

This creates a publisher with:

- message type `Float32`;
- topic name `/homelab/temperature`;
- queue depth `10`.

### Timer

```python
self.timer = self.create_timer(1.0, self.publish_temperature)
```

The timer calls `publish_temperature()` once per second.

### Message

```python
message = Float32()
message.data = float(temperature)
self.publisher.publish(message)
```

A typed ROS message is created, filled with a value, and published to the topic.

### Event loop

```python
rclpy.spin(node)
```

The event loop keeps the node running and processes timer callbacks until the user presses `Ctrl+C`.

## Completion checklist

- [ ] The package builds without errors.
- [ ] `ros2 run homelab_monitor temperature_publisher` starts the node.
- [ ] A new temperature is logged every second.
- [ ] `/homelab/temperature` uses `std_msgs/msg/Float32`.
- [ ] A second terminal can receive the messages.
- [ ] The process stops cleanly with `Ctrl+C`.

## Next task

Create a `temperature_monitor` subscriber that:

- listens to `/homelab/temperature`;
- prints normal temperatures as informational messages;
- produces a warning above 70 °C;
- accepts the warning threshold as a ROS 2 parameter.
