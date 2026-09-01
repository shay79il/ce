# SeaweedFS Remote Gateway Examples

These overlays enable `seaweedfs.remote` so KFP pipeline artifacts stay on in-cluster SeaweedFS while syncing to external AWS S3 or Azure Blob in the background.

Pass secrets at deploy time — do not commit credentials to git.

## AWS S3

```bash
helm upgrade --install mlrun-ce charts/mlrun-ce -n mlrun \
  -f <your-environment-values>.yaml \
  -f charts/mlrun-ce/examples/seaweedfs-remote-s3-overlay.yaml \
  --set storage.s3.accessKey="$AWS_ACCESS_KEY_ID" \
  --set storage.s3.secretKey="$AWS_SECRET_ACCESS_KEY"
```

Customize `bucket`, `seaweedfs.remote.s3.endpoint`, and `seaweedfs.remote.s3.region` in the overlay file.

## Azure Blob

**Option A — account name + key** (`accountName`/`accountKey` take precedence when both are set):

```bash
export AZURE_STORAGE_KEY="$(az storage account keys list \
  --account-name <ACCOUNT_NAME> --resource-group <RG> --query '[0].value' -o tsv)"

helm upgrade --install mlrun-ce charts/mlrun-ce -n mlrun \
  -f <your-environment-values>.yaml \
  -f charts/mlrun-ce/examples/seaweedfs-remote-azure-overlay.yaml \
  --set storage.azure.accountName="<ACCOUNT_NAME>" \
  --set storage.azure.accountKey="$AZURE_STORAGE_KEY" \
  --set storage.azure.containerName="<CONTAINER_NAME>" \
  --set seaweedfs.remote.bucket="<CONTAINER_NAME>"
```

**Option B — connection string only** (leave `accountName`/`accountKey` empty):

```bash
export AZURE_STORAGE_CONNECTION_STRING="$(az storage account show-connection-string \
  --name <ACCOUNT_NAME> --resource-group <RG> --query connectionString -o tsv)"

helm upgrade --install mlrun-ce charts/mlrun-ce -n mlrun \
  -f <your-environment-values>.yaml \
  -f charts/mlrun-ce/examples/seaweedfs-remote-azure-overlay.yaml \
  --set storage.azure.accountName="" \
  --set storage.azure.accountKey="" \
  --set storage.azure.connectionString="$AZURE_STORAGE_CONNECTION_STRING" \
  --set storage.azure.containerName="<CONTAINER_NAME>" \
  --set seaweedfs.remote.bucket="<CONTAINER_NAME>"
```

`seaweedfs.remote.bucket` must match `storage.azure.containerName`.

See also: [Kubeflow Pipelines object store configuration](https://www.kubeflow.org/docs/components/pipelines/operator-guides/configure-object-store/).
