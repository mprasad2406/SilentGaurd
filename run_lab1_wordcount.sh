#!/bin/bash

set -e

IMAGE_NAME="hadoop-wordcount-lab"
CONTAINER_NAME="hadoop-wordcount-container"

echo "========================================"
echo " Hadoop WordCount Lab"
echo "========================================"

echo ""
echo "[1/8] Creating Dockerfile..."

cat > Dockerfile <<'DOCKERFILE'
FROM eclipse-temurin:11-jdk-jammy

ENV HADOOP_VERSION=3.3.6
ENV HADOOP_HOME=/opt/hadoop
ENV PATH=$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin

RUN apt-get update && \
    apt-get install -y wget ssh rsync procps && \
    rm -rf /var/lib/apt/lists/*

RUN wget -q https://archive.apache.org/dist/hadoop/common/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz && \
    tar -xzf hadoop-${HADOOP_VERSION}.tar.gz -C /opt && \
    mv /opt/hadoop-${HADOOP_VERSION} ${HADOOP_HOME} && \
    rm hadoop-${HADOOP_VERSION}.tar.gz

RUN mkdir -p /lab/input /lab/output

WORKDIR /lab

CMD ["tail", "-f", "/dev/null"]
DOCKERFILE

echo "Dockerfile created."

echo ""
echo "[2/8] Building Docker image..."

docker build -t "$IMAGE_NAME" .

echo "Docker image built successfully."

echo ""
echo "[3/8] Removing old container if it exists..."

docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

echo ""
echo "[4/8] Starting Docker container..."

docker run -d \
    --name "$CONTAINER_NAME" \
    "$IMAGE_NAME"

echo "Container started."

echo ""
echo "[5/8] Creating Hadoop configuration..."

docker exec "$CONTAINER_NAME" bash -c '
mkdir -p $HADOOP_HOME/etc/hadoop

cat > $HADOOP_HOME/etc/hadoop/core-site.xml <<EOF
<configuration>
    <property>
        <name>fs.defaultFS</name>
        <value>file:///</value>
    </property>
</configuration>
EOF

cat > $HADOOP_HOME/etc/hadoop/mapred-site.xml <<EOF
<configuration>
    <property>
        <name>mapreduce.framework.name</name>
        <value>local</value>
    </property>
</configuration>
EOF

cat > $HADOOP_HOME/etc/hadoop/hdfs-site.xml <<EOF
<configuration>
    <property>
        <name>dfs.replication</name>
        <value>1</value>
    </property>
</configuration>
EOF

cat > $HADOOP_HOME/etc/hadoop/hadoop-env.sh <<EOF
export JAVA_HOME=/opt/java/openjdk
EOF
'

echo "Hadoop configuration completed."

echo ""
echo "[6/8] Creating WordCount Java program inside the container..."

docker exec "$CONTAINER_NAME" bash -c '
cat > /lab/WordCount.java <<EOF
import java.io.IOException;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.io.IntWritable;
import org.apache.hadoop.io.Text;
import org.apache.hadoop.mapreduce.Job;
import org.apache.hadoop.mapreduce.Mapper;
import org.apache.hadoop.mapreduce.Reducer;
import org.apache.hadoop.mapreduce.lib.input.FileInputFormat;
import org.apache.hadoop.mapreduce.lib.output.FileOutputFormat;

public class WordCount {

    public static class TokenizerMapper
            extends Mapper<Object, Text, Text, IntWritable> {

        private final static IntWritable one = new IntWritable(1);
        private Text word = new Text();

        public void map(
                Object key,
                Text value,
                Context context
        ) throws IOException, InterruptedException {

            String[] words = value.toString().split("\\\\s+");

            for (String currentWord : words) {
                if (!currentWord.isEmpty()) {
                    word.set(currentWord);
                    context.write(word, one);
                }
            }
        }
    }

    public static class IntSumReducer
            extends Reducer<Text, IntWritable, Text, IntWritable> {

        private IntWritable result = new IntWritable();

        public void reduce(
                Text key,
                Iterable<IntWritable> values,
                Context context
        ) throws IOException, InterruptedException {

            int sum = 0;

            for (IntWritable value : values) {
                sum += value.get();
            }

            result.set(sum);
            context.write(key, result);
        }
    }

    public static void main(String[] args) throws Exception {

        Configuration configuration = new Configuration();

        Job job = Job.getInstance(configuration, "word count");

        job.setJarByClass(WordCount.class);

        job.setMapperClass(TokenizerMapper.class);
        job.setCombinerClass(IntSumReducer.class);
        job.setReducerClass(IntSumReducer.class);

        job.setOutputKeyClass(Text.class);
        job.setOutputValueClass(IntWritable.class);

        FileInputFormat.addInputPath(job, new Path(args[0]));
        FileOutputFormat.setOutputPath(job, new Path(args[1]));

        System.exit(job.waitForCompletion(true) ? 0 : 1);
    }
}
EOF
'

echo "WordCount.java created inside the Docker container."

echo ""
echo "[7/8] Creating input files and running WordCount inside container..."

docker exec "$CONTAINER_NAME" bash -c '
set -e

cd /lab
rm -rf /lab/input /lab/output /lab/*.class /lab/wordcount.jar

mkdir -p /lab/input

cat > /lab/input/file1.txt <<EOF
the quick brown fox
jumps over the lazy dog
the quick brown fox jumps over the lazy dog
EOF

cat > /lab/input/file2.txt <<EOF
the quick brown fox
jumps over the lazy dog
dog barks
fox runs
dog and fox are friends
EOF

echo ""
echo "Input files:"
echo "------------"
cat /lab/input/file1.txt
cat /lab/input/file2.txt

echo ""
echo "Compiling WordCount.java..."

export HADOOP_CLASSPATH=$(hadoop classpath)
javac -classpath "$HADOOP_CLASSPATH" -d /lab /lab/WordCount.java

echo "Compilation successful."

echo ""
echo "Checking generated class files..."
ls -l /lab/WordCount*.class

echo ""
echo "Creating JAR file..."
jar -cvf wordcount.jar WordCount*.class

echo "JAR file created."

echo ""
echo "Running Hadoop WordCount..."
hadoop jar wordcount.jar WordCount /lab/input /lab/output

echo ""
echo "Final WordCount Output:"
echo "-----------------------"
cat /lab/output/part-r-00000
'

echo ""
echo "[8/8] Copying output to host machine..."

mkdir -p output

docker cp "$CONTAINER_NAME:/lab/output/part-r-00000" ./output/part-r-00000 2>/dev/null || true

echo ""
echo "========================================"
echo " Lab completed successfully"
echo "========================================"

echo ""
echo "Output saved on host at:"
echo "./output/part-r-00000"

echo ""
echo "================================================================"
echo " Container is kept running. Dropping into interactive shell..."
echo " You are now inside the container in /lab"
echo " Type 'exit' when you want to leave the container."
echo "hadoop jar wordcount.jar WordCount input output"
echo "================================================================"
echo ""

docker exec -it "$CONTAINER_NAME" bash