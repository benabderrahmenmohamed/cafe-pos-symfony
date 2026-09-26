<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;
use RuntimeException;

/**
 * Three malformed payloads answered VALIDATION_ERROR: see migrations/sql/0004_malformed_payloads.sql.
 *
 * Its own migration rather than more lines in 0001_schema.sql, because every database this server has
 * ever had has already run Version20260925000001 and will never run it again. This is how the fix
 * reaches them: as the next migration, once.
 */
final class Version20260926000004 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Three malformed payloads answered VALIDATION_ERROR, not SERVER_ERROR.';
    }

    public function up(Schema $schema): void
    {
        $this->connection->getNativeConnection()->exec($this->sql('0004_malformed_payloads.sql'));
    }

    public function down(Schema $schema): void
    {
        // The functions it replaces are whole bodies in 0001_schema.sql, and putting them back means
        // putting back three ways to answer a malformed request with a five-hundred. Not worth a way
        // down: a database that needs the old bodies is restored, not migrated backwards.
        $this->throwIrreversibleMigrationException('The previous function bodies are not kept apart from 0001_schema.sql.');
    }

    private function sql(string $name): string
    {
        $path = __DIR__ . '/sql/' . $name;
        $sql = file_get_contents($path);
        if ($sql === false) {
            throw new RuntimeException("The file {$path} cannot be read.");
        }

        return $sql;
    }
}
