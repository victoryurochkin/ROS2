// ROS 2 нода: раз в секунду публикует состояние CUDA в /cuda_verify/status.
// Позволяет проверить образ штатными средствами ROS (ros2 topic echo).
#include "cuda_verify/vector_add.hpp"

#include <rclcpp/rclcpp.hpp>
#include <std_msgs/msg/string.hpp>

#include <chrono>
#include <memory>
#include <string>

class CudaInfoNode : public rclcpp::Node
{
public:
  CudaInfoNode()
  : Node("cuda_info_node")
  {
    publisher_ = create_publisher<std_msgs::msg::String>("cuda_verify/status", 10);
    const auto period = std::chrono::milliseconds(
      declare_parameter<int>("publish_period_ms", 1000));
    timer_ = create_wall_timer(period, [this]() {publish();});

    RCLCPP_INFO(get_logger(), "%s", cuda_verify::describe_versions().c_str());
    RCLCPP_INFO(get_logger(), "%s", cuda_verify::describe_devices().c_str());
  }

private:
  void publish()
  {
    std_msgs::msg::String msg;
    std::string error;
    const bool ok = cuda_verify::run_vector_add(1 << 16, error);
    msg.data = cuda_verify::describe_devices() + "\nvector_add=" +
      (ok ? "OK" : ("FAIL: " + error));
    publisher_->publish(msg);
  }

  rclcpp::Publisher<std_msgs::msg::String>::SharedPtr publisher_;
  rclcpp::TimerBase::SharedPtr timer_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<CudaInfoNode>());
  rclcpp::shutdown();
  return 0;
}
