<?php

declare(strict_types=1);

namespace App\Tests;

use Doctrine\DBAL\Connection;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;

/** The kernel boots and the test database answers: everything else is built on these two. */
final class SmokeTest extends KernelTestCase
{
    public function testTheKernelBootsAndItsDatabaseAnswers(): void
    {
        self::bootKernel();

        $connection = self::getContainer()->get(Connection::class);

        self::assertSame(1, (int) $connection->fetchOne('select 1'));
        // Whatever the database is called on this machine, the tests write to one of their own:
        // doctrine.yaml adds `_test` to its name in the test environment, and nothing else does.
        self::assertStringEndsWith(
            '_test',
            (string) $connection->fetchOne('select current_database()'),
            'the tests must never run against the database a café uses',
        );
    }
}
