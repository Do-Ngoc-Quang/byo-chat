package blob

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/aws/smithy-go"
)

// S3Config cấu hình kho Amazon S3 (ADR 0014). Chạy thật: chỉ cần Bucket (+Region); thông tin xác thực lấy từ IAM role
// theo chuỗi mặc định của SDK. Dev/LocalStack: thêm Endpoint, PathStyle và khóa tĩnh.
type S3Config struct {
	Bucket    string
	Region    string
	Endpoint  string // rỗng = AWS S3; LocalStack: http://localhost:4566
	PathStyle bool   // LocalStack cần
	AccessKey string // chỉ dev; rỗng = chuỗi xác thực mặc định (IAM role)
	SecretKey string
	TTL       time.Duration // hạn URL ký, mặc định 15 phút
	MaxSize   uint64        // kích thước tối đa mỗi đối tượng, mặc định 256 MiB (như Dev)
}

// S3 cấp URL ký sẵn (SigV4) cho bucket S3. Thỏa `Signer`.
type S3 struct {
	cli     *s3.Client
	presign *s3.PresignClient
	bucket  string
	ttl     time.Duration
	max     uint64
}

func NewS3(ctx context.Context, c S3Config) (*S3, error) {
	if c.Bucket == "" {
		return nil, errors.New("blob: thiếu tên bucket S3")
	}
	if c.Region == "" {
		c.Region = "us-east-1"
	}
	opts := []func(*awsconfig.LoadOptions) error{awsconfig.WithRegion(c.Region)}
	if c.AccessKey != "" {
		opts = append(opts, awsconfig.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(c.AccessKey, c.SecretKey, "")))
	}
	cfg, err := awsconfig.LoadDefaultConfig(ctx, opts...)
	if err != nil {
		return nil, fmt.Errorf("blob: cấu hình AWS: %w", err)
	}
	cli := s3.NewFromConfig(cfg, func(o *s3.Options) {
		if c.Endpoint != "" {
			o.BaseEndpoint = aws.String(c.Endpoint)
		}
		o.UsePathStyle = c.PathStyle
	})
	s := &S3{cli: cli, presign: s3.NewPresignClient(cli), bucket: c.Bucket, ttl: c.TTL, max: c.MaxSize}
	if s.ttl == 0 {
		s.ttl = 15 * time.Minute
	}
	if s.max == 0 {
		s.max = 256 << 20
	}
	return s, nil
}

// PresignPut cấp MỘT URL PUT có ký độ dài nội dung (S3 từ chối nếu thân khác `size`). Một PUT đủ tới 5 GiB, rộng hơn
// MaxSize của sao lưu. Tải nhiều phần (media lớn, resume theo khối) cần bước Complete do server gọi: làm ở giai đoạn 5.
func (s *S3) PresignPut(ctx context.Context, key string, size uint64) ([]string, uint32, error) {
	if size == 0 || size > s.max {
		return nil, 0, fmt.Errorf("blob: kích thước %d ngoài (0, %d]", size, s.max)
	}
	r, err := s.presign.PresignPutObject(ctx, &s3.PutObjectInput{
		Bucket: aws.String(s.bucket), Key: aws.String(key), ContentLength: aws.Int64(int64(size)),
	}, s3.WithPresignExpires(s.ttl))
	if err != nil {
		return nil, 0, err
	}
	return []string{r.URL}, uint32(size), nil
}

func (s *S3) PresignGet(ctx context.Context, key string) (string, error) {
	r, err := s.presign.PresignGetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(s.bucket), Key: aws.String(key)}, s3.WithPresignExpires(s.ttl))
	if err != nil {
		return "", err
	}
	return r.URL, nil
}

func (s *S3) Exists(ctx context.Context, key string) (bool, error) {
	_, err := s.cli.HeadObject(ctx, &s3.HeadObjectInput{Bucket: aws.String(s.bucket), Key: aws.String(key)})
	if err == nil {
		return true, nil
	}
	var nf *types.NotFound
	var ae smithy.APIError
	if errors.As(err, &nf) || (errors.As(err, &ae) && (ae.ErrorCode() == "NotFound" || ae.ErrorCode() == "NoSuchKey")) {
		return false, nil
	}
	return false, err
}

// EnsureLifecycle đặt quy tắc xóa đối tượng sau `days` ngày cho tiền tố `prefix` (spec: media 30 ngày, cùng TTL
// ciphertext). Chạy thật nên đặt bằng hạ tầng (IaC); hàm này cho dev/LocalStack và kiểm thử.
func (s *S3) EnsureLifecycle(ctx context.Context, prefix string, days int32) error {
	_, err := s.cli.PutBucketLifecycleConfiguration(ctx, &s3.PutBucketLifecycleConfigurationInput{
		Bucket: aws.String(s.bucket),
		LifecycleConfiguration: &types.BucketLifecycleConfiguration{Rules: []types.LifecycleRule{{
			ID:         aws.String("expire-" + prefix),
			Status:     types.ExpirationStatusEnabled,
			Filter:     &types.LifecycleRuleFilter{Prefix: aws.String(prefix)},
			Expiration: &types.LifecycleExpiration{Days: aws.Int32(days)},
		}}},
	})
	return err
}

// EnsureBucket tạo bucket nếu chưa có (dev/LocalStack, test).
func (s *S3) EnsureBucket(ctx context.Context) error {
	_, err := s.cli.CreateBucket(ctx, &s3.CreateBucketInput{Bucket: aws.String(s.bucket)})
	var own *types.BucketAlreadyOwnedByYou
	if errors.As(err, &own) {
		return nil
	}
	return err
}
