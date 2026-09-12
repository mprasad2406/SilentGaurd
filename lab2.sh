#!/bin/bash

set -e

IMAGE_NAME="hdfs-java-lab"
COMPOSE_PROJECT="lab2-hdfs"

echo "=============================================="
echo " Lab 2 - HDFS File Operations using Java API"
echo "=============================================="

echo ""
echo "[1/9] Creating project files..."

mkdir -p lab2-hdfs
cd lab2-hdfs

cat > Dockerfile <<'DOCKERFILE'
FROM eclipse-temurin:8-jdk-jammy AS jdk
FROM apache/hadoop:3.3.6

USER root

# Copy full OpenJDK (javac, jar, etc.) into the image
COPY --from=jdk /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH=$JAVA_HOME/bin:$PATH

RUN mkdir -p /lab/classes /lab/input /lab/output /hadoop/dfs/name /hadoop/dfs/data

WORKDIR /lab
DOCKERFILE

cat > docker-compose.yml <<'COMPOSE'
services:
  namenode:
    build: .
    container_name: lab2-namenode
    hostname: namenode
    user: root
    command: ["bash", "-c", "if [ ! -d /hadoop/dfs/name/current ]; then echo 'Formatting NameNode...'; hdfs namenode -format -force -nonInteractive; fi; hdfs namenode"]
    ports:
      - "9870:9870"
      - "8020:8020"
    environment:
      - CORE-SITE.XML_fs.defaultFS=hdfs://namenode:8020
      - HDFS-SITE.XML_dfs.namenode.rpc-address=namenode:8020
      - HDFS-SITE.XML_dfs.replication=1
      - HDFS-SITE.XML_dfs.namenode.name.dir=file:///hadoop/dfs/name
      - HDFS-SITE.XML_dfs.permissions.enabled=false
    volumes:
      - namenode_data:/hadoop/dfs/name

  datanode:
    build: .
    container_name: lab2-datanode
    hostname: datanode
    user: root
    command: ["hdfs", "datanode"]
    environment:
      - CORE-SITE.XML_fs.defaultFS=hdfs://namenode:8020
      - HDFS-SITE.XML_dfs.namenode.rpc-address=namenode:8020
      - HDFS-SITE.XML_dfs.replication=1
      - HDFS-SITE.XML_dfs.datanode.data.dir=file:///hadoop/dfs/data
      - HDFS-SITE.XML_dfs.permissions.enabled=false
    volumes:
      - datanode_data:/hadoop/dfs/data
    depends_on:
      - namenode

volumes:
  namenode_data:
  datanode_data:
COMPOSE

echo "Dockerfile and docker-compose.yml created."

echo ""
echo "[2/9] Stopping old containers and starting HDFS cluster..."

docker compose down -v --remove-orphans 2>/dev/null || true

docker compose build

docker compose up -d

echo "HDFS cluster started."

echo ""
echo "[3/9] Waiting for NameNode and DataNode to initialize..."

for i in {1..30}; do
  if docker exec lab2-namenode hdfs dfsadmin -safemode get 2>/dev/null | grep -q "Safe mode"; then
    echo "NameNode is up! Turning safe mode off..."
    docker exec lab2-namenode hdfs dfsadmin -safemode leave 2>/dev/null || true
    break
  fi
  echo "Waiting for NameNode... ($i/30)"
  sleep 2
done

echo ""
echo "[4/9] Checking running containers..."

docker compose ps

echo ""
echo "[5/9] Creating HDFS student directory..."

docker exec lab2-namenode bash -c '
hdfs dfs -mkdir -p /user/student
hdfs dfs -ls /user
'

echo ""
echo "[6/9] Creating HdfsDemo.java inside the NameNode container..."

docker exec lab2-namenode bash -c 'cat > /lab/HdfsDemo.java <<'\''EOF'\''
import java.io.IOException;
import java.net.URI;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.FSDataInputStream;
import org.apache.hadoop.fs.FSDataOutputStream;
import org.apache.hadoop.fs.FileStatus;
import org.apache.hadoop.fs.FileSystem;
import org.apache.hadoop.fs.Path;

public class HdfsDemo {

    public static void main(String[] args) throws Exception {

        String uri = "hdfs://namenode:8020";

        Configuration conf = new Configuration();
        FileSystem fs = FileSystem.get(URI.create(uri), conf);

        Path file = new Path("/user/student/quangle.txt");

        // WRITE: create() gives an output stream
        FSDataOutputStream out = fs.create(file, true);
        out.writeBytes("On the top of the Crumpetty Tree\n");
        out.writeBytes("The Quangle Wangle sat\n");
        out.close();

        System.out.println("Wrote file: " + file);

        // READ + SEEK: open() gives a seekable stream
        FSDataInputStream in = fs.open(file);
        byte[] buffer = new byte[32];
        int bytesRead = in.read(buffer);
        System.out.println("From start : " + new String(buffer, 0, bytesRead > 0 ? bytesRead : 0).trim());

        in.seek(33);
        byte[] buf2 = new byte[32];
        int bytesRead2 = in.read(buf2);
        System.out.println("After seek : " + new String(buf2, 0, bytesRead2 > 0 ? bytesRead2 : 0).trim());
        in.close();

        // METADATA
        FileStatus st = fs.getFileStatus(file);
        System.out.println("Length     : " + st.getLen() + " bytes");
        System.out.println("Replication: " + st.getReplication());

        // LIST: listStatus on a directory
        System.out.println("--- listStatus /user/student ---");
        FileStatus[] list = fs.listStatus(new Path("/user/student"));
        if (list != null) {
            for (FileStatus s : list) {
                System.out.println(" " + s.getPath().getName());
            }
        }

        // GLOB: wildcard matching
        System.out.println("--- globStatus *.txt ---");
        FileStatus[] matches = fs.globStatus(new Path("/user/student/*.txt"));
        if (matches != null) {
            for (FileStatus s : matches) {
                System.out.println(" " + s.getPath().getName());
            }
        }

        fs.close();
    }
}
EOF
'

docker exec lab2-namenode cat /lab/HdfsDemo.java

echo ""
echo "[7/9] Compiling and packaging HdfsDemo.java..."

docker exec lab2-namenode bash -c '
set -e
export HADOOP_CLASSPATH=$(hadoop classpath)

rm -rf /lab/classes /lab/hdfsdemo.jar
mkdir -p /lab/classes

javac \
    -classpath "$HADOOP_CLASSPATH" \
    -d /lab/classes \
    /lab/HdfsDemo.java

jar -cvf /lab/hdfsdemo.jar -C /lab/classes .

echo ""
echo "Compilation and JAR creation completed."
'

echo ""
echo "[8/9] Running HDFS Java program..."

docker exec lab2-namenode bash -c '
echo ""
echo "Running HdfsDemo..."
echo "------------------"

hadoop jar /lab/hdfsdemo.jar HdfsDemo

echo ""
echo "Confirming file contents from HDFS..."
echo "-------------------------------------"

hdfs dfs -cat /user/student/quangle.txt
'

echo ""
echo "[9/9] Adding a second file and running the program again..."

docker exec lab2-namenode bash -c '
echo "hello hdfs" | hdfs dfs -put -f - /user/student/notes.txt

echo ""
echo "Running HdfsDemo again..."
echo "------------------------"

hadoop jar /lab/hdfsdemo.jar HdfsDemo
'

echo ""
echo "=============================================="
echo " Lab 2 completed successfully"
echo "=============================================="

echo ""
echo "NameNode Web UI:"
echo "http://localhost:9870"

echo ""
echo "================================================================"
echo " Containers are kept running. Dropping into interactive shell..."
echo " You are now inside the NameNode container in /lab"
echo "hadoop jar hdfsdemo.jar HdfsDemo"
echo " Type 'exit' when you want to leave the container."
echo "================================================================"
echo ""

docker exec -it lab2-namenode bash
