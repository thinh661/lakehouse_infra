from pyspark.sql import SparkSession
import time

# IP của một Node trong cụm RKE2
NODE_IP = "192.168.49.141"  # Hãy thay bằng IP thực tế của node trong cụm RKE2
PORT = "30052"          # Cổng NodePort đã cấu hình

print(f"Đang kết nối tới Spark Connect tại sc://{NODE_IP}:{PORT} ...")

try:
    # Khởi tạo session kết nối
    spark = SparkSession.builder.remote(f"sc://{NODE_IP}:{PORT}").getOrCreate()
    
    print("\n==========================================")
    print("  KẾT NỐI THÀNH CÔNG TỚI SPARK CONNECT!   ")
    print("==========================================\n")
    
    # Phép toán thử nghiệm 1: Tạo DataFrame
    print("1. Thử nghiệm tạo DataFrame:")
    data = [("Thinh", 28), ("AI Assistant", 2), ("RKE2 Cluster", 1)]
    df = spark.createDataFrame(data, ["Name", "Age"])
    df.show()
    
    # Phép toán thử nghiệm 2: Tính toán phân tán lớn hơn
    print("2. Thử nghiệm tính toán count lớn (sẽ kích hoạt Executor mọc lên):")
    count = spark.range(1, 1000000).count()
    print(f"👉 Kết quả đếm số dòng: {count}")
    print("==========================================\n")
    
    # Chờ 30 giây để bạn có thời gian kiểm tra Executor pods trên Kubernetes
    print("Giữ kết nối trong 30 giây để kiểm tra Pod co giãn...")
    print("Bạn có thể chạy 'kubectl get pods -n spark-operator' trên Bastion lúc này.")
    time.sleep(30)
    
except Exception as e:
    print("\n[LỖI KẾT NỐI] Không thể kết nối tới Spark Connect Server:")
    print(e)
    print("\nVui lòng kiểm tra:")
    print("1. Trạng thái Pod driver: 'kubectl get pods -n spark-operator'")
    print(f"2. IP node '{NODE_IP}' có ping được từ máy chạy script này không.")
    print(f"3. Cổng NodePort '{PORT}' đã được apply và mở chưa.")
