# Build Custom Spark Image with Spark Connect for Offline Environment
FROM docker.io/apache/spark:3.5.0

# Switch to root to copy files and set permissions
USER root

# Copy the Spark Connect JAR into the Spark jars directory
COPY jars/spark-connect_2.12-3.5.0.jar /opt/spark/jars/

# (Optional) Add other production connectors if needed
# COPY jars/postgresql-42.6.0.jar /opt/spark/jars/
# COPY jars/aws-java-sdk-bundle-1.12.262.jar /opt/spark/jars/
# COPY jars/hadoop-aws-3.3.4.jar /opt/spark/jars/

# Revert back to the default non-root spark user (UID 185)
USER 185
