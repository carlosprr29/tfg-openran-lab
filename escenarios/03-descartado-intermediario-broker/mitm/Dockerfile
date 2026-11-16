FROM python:3.11-slim
RUN pip install --no-cache-dir pyzmq
COPY mitm.py /opt/mitm.py
CMD ["python3", "/opt/mitm.py"]
