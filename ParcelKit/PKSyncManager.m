//
//  PKSyncManager.m
//  ParcelKit
//
//  Copyright (c) 2013 Overcommitted, LLC. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

#import "PKSyncManager.h"
#import "NSManagedObject+ParcelKit.h"
#import "DBRecord+ParcelKit.h"
#import "PKIndexedRelationshipInfo.h"

NSString * const PKDefaultSyncAttributeName = @"syncID";
static NSUInteger const PKFetchRequestBatchSize = 25;

@interface PKSyncManager ()
@property (nonatomic, strong, readwrite) NSManagedObjectContext *managedObjectContext;
@property (nonatomic, strong, readwrite) DBDatastore *datastore;
@property (nonatomic, strong) NSMutableDictionary *tablesKeyedByEntityName;
@property (nonatomic) BOOL observing;
@property (nonatomic, strong) NSMutableArray *indexedRelationships;
@end

@implementation PKSyncManager

+ (NSString *)syncID
{
    return [[[NSUUID UUID] UUIDString] stringByReplacingOccurrencesOfString:@"-" withString:@""];
}

- (id)init
{
    self = [super init];
    if (self) {
        _tablesKeyedByEntityName = [[NSMutableDictionary alloc] init];
        _syncAttributeName = PKDefaultSyncAttributeName;
        _indexedRelationships = [[NSMutableArray alloc] initWithCapacity:0];
    }
    return self;
}

- (id)initWithManagedObjectContext:(NSManagedObjectContext *)managedObjectContext datastore:(DBDatastore *)datastore
{
    self = [self init];
    if (self) {
        _managedObjectContext = managedObjectContext;
        _datastore = datastore;
    }
    return self;
}

#pragma mark - Entity and Table map

- (void)setTablesForEntityNamesWithDictionary:(NSDictionary *)keyedTables
{
    for (NSString *entityName in [self entityNames]) {
        [self removeTableForEntityName:entityName];
    }

    __weak typeof(self) weakSelf = self;
    [keyedTables enumerateKeysAndObjectsUsingBlock:^(NSString *entityName, NSString *tableID, BOOL *stop) {
        
        typeof(self) strongSelf = weakSelf; if (!strongSelf) return;
        [strongSelf setTable:tableID forEntityName:entityName];
    }];
}

- (void)setTable:(NSString *)tableID forEntityName:(NSString *)entityName
{
    // Assert that the entity has a string attribute named syncID.
    NSEntityDescription *entity = [NSEntityDescription entityForName:entityName inManagedObjectContext:self.managedObjectContext];
    NSAttributeDescription *attributeDescription = [[entity attributesByName] objectForKey:self.syncAttributeName];
    NSAssert([attributeDescription attributeType] == NSStringAttributeType, @"Entity “%@” must contain a string attribute named “%@”", entityName, self.syncAttributeName);
    
    [self.tablesKeyedByEntityName setObject:tableID forKey:entityName];
}

- (void)removeTableForEntityName:(NSString *)entityName
{
    [self.tablesKeyedByEntityName removeObjectForKey:entityName];
}

- (NSDictionary *)tablesByEntityName
{
    return [[NSDictionary alloc] initWithDictionary:self.tablesKeyedByEntityName];
}

- (NSArray *)tableIDs
{
    return [self.tablesKeyedByEntityName allValues];
}

- (NSArray *)entityNames
{
    return [self.tablesKeyedByEntityName allKeys];
}

- (NSString *)tableForEntityName:(NSString *)entityName
{
    return [self.tablesKeyedByEntityName objectForKey:entityName];
}

- (NSString *)entityNameForTable:(NSString *)tableID
{
    return [[self.tablesKeyedByEntityName allKeysForObject:tableID] lastObject];
}

- (void)entityName:(NSString *)parentEntity hasIndexedToManyRelationship:(NSString *)toManyRel toEntity:(NSString *)childEntity withInverseRelationship:(NSString *)inverseRel andIndexName:(NSString *)indexName {
    
    PKIndexedRelationshipInfo *iri = [[PKIndexedRelationshipInfo alloc] init];
    iri.parentEntity = parentEntity;
    iri.toManyRel = toManyRel;
    iri.childEntity = childEntity;
    iri.inverseRel = inverseRel;
    iri.indexName = indexName;
    
    [self.indexedRelationships addObject:iri];
}

- (PKIndexedRelationshipInfo *)indexedRelationshipInfoForChildEntity:(NSString *)childEntity {
    
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"childEntity == %@", childEntity];
    NSArray *results = [self.indexedRelationships filteredArrayUsingPredicate:predicate];
    if (results && [results count] > 0) {
        return [results objectAtIndex:0];
    }
    else {
        return nil;
    }
}

#pragma mark - Observing methods
- (BOOL)isObserving
{
    return self.observing;
}

- (void)startObserving
{
    if ([self isObserving]) return;
    self.observing = YES;
    
    __weak typeof(self) weakSelf = self;
    [self.datastore addObserver:self block:^ {
        
        typeof(self) strongSelf = weakSelf; if (!strongSelf) return;
        if (![strongSelf isObserving]) return;
        
        if (strongSelf.datastore.status & DBDatastoreIncoming) {
            
            DBError *error = nil;
            NSDictionary *changes = [strongSelf.datastore sync:&error];
            if (changes) {
                [strongSelf updateCoreDataWithDatastoreChanges:changes];
            }
            else {
                NSLog(@"Error syncing with Dropbox: %@", error);
            }
        }
    }];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(managedObjectContextWillSave:) name:NSManagedObjectContextWillSaveNotification object:self.managedObjectContext];
}

- (void)stopObserving {
    
    if (![self isObserving]) return;
    self.observing = NO;
    
    [self.datastore removeObserver:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSManagedObjectContextWillSaveNotification object:self.managedObjectContext];
}

#pragma mark - Updating Core Data

- (void)updateCoreDataWithDatastoreChanges:(NSDictionary *)changes {
    
    if ([changes count] == 0) {
        return;
    }
    
    NSManagedObjectContext *managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    [managedObjectContext setPersistentStoreCoordinator:[self.managedObjectContext persistentStoreCoordinator]];
    [managedObjectContext setUndoManager:nil];
    
    __weak typeof(self) weakSelf = self;
    [changes enumerateKeysAndObjectsUsingBlock:^(NSString *tableID, NSArray *records, BOOL *stop) {
        
        typeof(self) strongSelf = weakSelf;
        
        if (!strongSelf) {
            return;
        }
        
        for (DBRecord *record in records) {
            
            NSString *entityName = [strongSelf entityNameForTable:tableID];
            if (!entityName) {
                continue;
            }
            
            NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:entityName];
            [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"%K == %@", strongSelf.syncAttributeName, record.recordId]];
            [fetchRequest setFetchLimit:1];
            
            NSError *error = nil;
            NSArray *managedObjects = [managedObjectContext executeFetchRequest:fetchRequest error:&error];
            if (managedObjects)  {
                
                NSManagedObject *managedObject = [managedObjects lastObject];
                
                if ([record isDeleted]) {
                    if (managedObject) {
                        [managedObjectContext deleteObject:managedObject];
                    }
                }
                else {
                    if (!managedObject) {
                        managedObject = [NSEntityDescription insertNewObjectForEntityForName:entityName inManagedObjectContext:managedObjectContext];
                        [managedObject setValue:record.recordId forKey:strongSelf.syncAttributeName];
                    }
                    
                    [managedObject pk_setPropertiesWithRecord:record syncAttributeName:strongSelf.syncAttributeName];
                }
            }
            else {
                NSLog(@"Error executing fetch request: %@", error);
            }
        }
    }];
    
    if ([managedObjectContext hasChanges]) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(syncManagedObjectContextDidSave:) name:NSManagedObjectContextDidSaveNotification object:managedObjectContext];
        NSError *error = nil;
        if (![managedObjectContext save:&error]) {
            NSLog(@"Error saving managed object context: %@", error);
        }
        [[NSNotificationCenter defaultCenter] removeObserver:self name:NSManagedObjectContextDidSaveNotification object:managedObjectContext];
    }
}

- (void)syncManagedObjectContextDidSave:(NSNotification *)notification {
    [self.managedObjectContext mergeChangesFromContextDidSaveNotification:notification];
}

#pragma mark - Updating Datastore

- (void)managedObjectContextWillSave:(NSNotification *)notification {
    
    if (![self isObserving]) {
        return;
    }
    
    NSManagedObjectContext *managedObjectContext = notification.object;
    if (self.managedObjectContext != managedObjectContext) {
        return;
    }
    
    NSSet *deletedObjects = [managedObjectContext deletedObjects];
    for (NSManagedObject *managedObject in deletedObjects) {
        
        NSString *tableID = [self tableForEntityName:[[managedObject entity] name]];
        if (!tableID) {
            continue;
        }
        
        DBTable *table = [self.datastore getTable:tableID];
        DBError *error = nil;
        DBRecord *record = [table getRecord:[managedObject primitiveValueForKey:self.syncAttributeName] error:&error];
        if (record) {
            [record deleteRecord];
        }
        else if (error) {
            NSLog(@"Error getting datastore record: %@", error);
        }
    };
    
    NSMutableSet *managedObjectsInsertedOrUpdated = [[NSMutableSet alloc] init];
    [managedObjectsInsertedOrUpdated unionSet:[managedObjectContext insertedObjects]];
    [managedObjectsInsertedOrUpdated unionSet:[managedObjectContext updatedObjects]];
    
    NSSet *managedObjectsWithoutSyncId = [managedObjectsInsertedOrUpdated filteredSetUsingPredicate:[NSPredicate predicateWithFormat:@"%K == nil", self.syncAttributeName]];
    for (NSManagedObject *managedObject in managedObjectsWithoutSyncId) {
        [managedObject setPrimitiveValue:[[self class] syncID] forKey:self.syncAttributeName];
    };
    
    for (NSManagedObject *managedObject in managedObjectsInsertedOrUpdated) {
        [self updateDatastoreWithManagedObject:managedObject];
    };
    
    //
    // All local changes in core data have now been propogated to the local dropbox datastore
    // Now we need to sort any DBLists to match the indices
    //
    for (NSManagedObject *managedObject in managedObjectsInsertedOrUpdated) {
        NSString *entityName = [[managedObject entity] name];
        PKIndexedRelationshipInfo *iri = [self indexedRelationshipInfoForChildEntity:entityName];
        if (iri) {
            NSManagedObject *parent = [managedObject valueForKey:iri.inverseRel];
            NSSet *children = [parent valueForKey:iri.toManyRel];
            
            // Get the parent entity
            // Get the set of child entities
            // Sort the child entities by index, in an array
            // Loop through them and sort the DBList
        }
    };
    
    DBError *error = nil;
    NSDictionary *changes = [self.datastore sync:&error];
    if (changes) {
        [self updateCoreDataWithDatastoreChanges:changes];
    }
    else {
        NSLog(@"Error syncing with Dropbox: %@", error);
    }
}

- (void)updateDatastoreWithManagedObject:(NSManagedObject *)managedObject {
    
    NSString *tableID = [self tableForEntityName:[[managedObject entity] name]];
    if (!tableID) {
        return;
    }
    
    DBTable *table = [self.datastore getTable:tableID];
    DBError *error = nil;
    DBRecord *record = [table getOrInsertRecord:[managedObject valueForKey:self.syncAttributeName] fields:nil inserted:NULL error:&error];
    if (record) {
        [record pk_setFieldsWithManagedObject:managedObject syncAttributeName:self.syncAttributeName];
    }
    else {
        NSLog(@"Error getting or inserting datatore record: %@", error);
    }
}

@end
