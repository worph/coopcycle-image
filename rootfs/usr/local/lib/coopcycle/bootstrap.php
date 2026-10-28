<?php
// Small first-boot probes the entrypoint needs and bin/console does not offer:
// waiting for the database, telling a fresh database from an installed one,
// and creating the S3 buckets the app writes uploads to.
//
//   php bootstrap.php wait-db [seconds]
//   php bootstrap.php has-schema        exit 0 when the app's tables exist
//   php bootstrap.php has-user <name>   exit 0 when that user exists
//   php bootstrap.php s3-buckets [seconds]
//   php bootstrap.php set-password <name>   new password in $COOPCYCLE_ADMIN_PASSWORD
//
// set-password exists because `nucleos:user:change-password` reports success
// and saves nothing: it only sets the unmapped plainPassword field, Doctrine
// sees no change, and the listener that would hash it never fires. This
// writes the hash itself, with the algorithm the app's `auto` hasher uses
// (bcrypt, cost 13), so the app verifies it as one of its own.

require '/var/www/html/vendor/autoload.php';

function env(string $name, string $default = ''): string
{
    $v = getenv($name);
    return ($v === false || $v === '') ? $default : $v;
}

function pdo(): PDO
{
    $dsn = sprintf(
        'pgsql:host=%s;port=%s;dbname=%s;sslmode=%s',
        env('COOPCYCLE_DB_HOST', 'postgres'),
        env('COOPCYCLE_DB_PORT', '5432'),
        env('COOPCYCLE_DB_NAME', 'coopcycle'),
        env('COOPCYCLE_POSTGRES_SSLMODE', 'disable')
    );
    return new PDO($dsn, env('COOPCYCLE_DB_USER'), env('COOPCYCLE_DB_PASSWORD'), [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_TIMEOUT => 5,
    ]);
}

function retry(int $seconds, string $what, callable $fn)
{
    $deadline = time() + $seconds;
    while (true) {
        try {
            return $fn();
        } catch (Throwable $e) {
            if (time() >= $deadline) {
                fwrite(STDERR, "$what: giving up: {$e->getMessage()}\n");
                exit(1);
            }
            fwrite(STDERR, "$what: waiting ({$e->getMessage()})\n");
            sleep(3);
        }
    }
}

$cmd = $argv[1] ?? '';

switch ($cmd) {
    case 'wait-db':
        retry((int) ($argv[2] ?? 300), 'database', fn () => pdo()->query('SELECT 1'));
        exit(0);

    case 'has-schema':
        $found = pdo()->query("SELECT to_regclass('public.api_user') IS NOT NULL")->fetchColumn();
        exit($found ? 0 : 1);

    case 'has-user':
        $stmt = pdo()->prepare('SELECT 1 FROM api_user WHERE username = ?');
        $stmt->execute([$argv[2] ?? '']);
        exit($stmt->fetchColumn() ? 0 : 1);

    case 's3-buckets':
        $s3 = new Aws\S3\S3Client([
            'endpoint' => env('S3_ENDPOINT'),
            'region' => env('S3_REGION', 'us-east-1'),
            'version' => 'latest',
            'use_path_style_endpoint' => true,
            'credentials' => [
                'key' => env('S3_CREDENTIALS_KEY'),
                'secret' => env('S3_CREDENTIALS_SECRET'),
            ],
        ]);
        $existing = retry((int) ($argv[2] ?? 300), 'object storage', function () use ($s3) {
            return array_column($s3->listBuckets()['Buckets'] ?? [], 'Name');
        });
        // The same three upstream's rustfs/init.sh creates. Uploaded images are
        // read back by the app itself (liip/imagine), never by the browser, so
        // no bucket needs a public policy.
        foreach (['images', 'exports', 'edifact'] as $bucket) {
            if (!in_array($bucket, $existing, true)) {
                $s3->createBucket(['Bucket' => $bucket]);
                echo "created bucket $bucket\n";
            }
        }
        exit(0);

    case 'set-password':
        $password = env('COOPCYCLE_ADMIN_PASSWORD');
        if ($password === '') {
            fwrite(STDERR, "COOPCYCLE_ADMIN_PASSWORD is empty\n");
            exit(1);
        }
        $hash = password_hash($password, PASSWORD_BCRYPT, ['cost' => 13]);
        $stmt = pdo()->prepare('UPDATE api_user SET password = ?, salt = NULL WHERE username = ?');
        $stmt->execute([$hash, $argv[2] ?? '']);
        if ($stmt->rowCount() !== 1) {
            fwrite(STDERR, "no such user\n");
            exit(1);
        }
        echo "password changed\n";
        exit(0);

    default:
        fwrite(STDERR, "usage: bootstrap.php wait-db|has-schema|has-user|s3-buckets|set-password\n");
        exit(2);
}
