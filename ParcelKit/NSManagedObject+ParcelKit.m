//
//  NSManagedObject+ParcelKit.m
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

#import "NSManagedObject+ParcelKit.h"
#import <Dropbox/Dropbox.h>

NSString * const PKInvalidAttributeValueException = @"Invalid attribute value";
static NSString * const PKInvalidAttributeValueExceptionFormat = @"“%@.%@” expected “%@” to be of type “%@” but is “%@”";

@implementation NSManagedObject (ParcelKit)

- (void)pk_setPropertiesWithRecord:(DBRecord *)bindToThisDBRecord syncAttributeName:(NSString *)syncAttributeName {
    
    NSString *entityName = [[self entity] name];
    
    __weak typeof(self) weakSelf = self;
    
    NSDictionary *propertiesByName = [[self entity] propertiesByName];
    
    [propertiesByName enumerateKeysAndObjectsUsingBlock:^(NSString *nameOfPropertyInCoreData, NSPropertyDescription *propertyDescription, BOOL *stop) {
        
        typeof(self) strongSelf = weakSelf;
        
        if (!strongSelf) {
            return;
        }
        
        if ([nameOfPropertyInCoreData isEqualToString:syncAttributeName] || [propertyDescription isTransient]) {
            return;
        }
        
        //
        // ATTRIBUTES
        //
        if ([propertyDescription isKindOfClass:[NSAttributeDescription class]]) {
            
            NSAttributeType attributeType = [(NSAttributeDescription *)propertyDescription attributeType];
            
            id value = [bindToThisDBRecord objectForKey:nameOfPropertyInCoreData];
            
            if (value) {
                
                if ((attributeType == NSStringAttributeType) && (![value isKindOfClass:[NSString class]])) {
                    
                    if ([value respondsToSelector:@selector(stringValue)]) {
                        value = [value stringValue];
                    }
                    else {
                        [NSException raise:PKInvalidAttributeValueException format:PKInvalidAttributeValueExceptionFormat, entityName, nameOfPropertyInCoreData, value, [NSString class], [value class]];
                    }
                }
                else if (((attributeType == NSInteger16AttributeType) || (attributeType == NSInteger32AttributeType) || (attributeType == NSInteger64AttributeType)) && (![value isKindOfClass:[NSNumber class]])) {
                    
                    if ([value respondsToSelector:@selector(integerValue)]) {
                        value = [NSNumber numberWithInteger:[value integerValue]];
                    }
                    else {
                        [NSException raise:PKInvalidAttributeValueException format:PKInvalidAttributeValueExceptionFormat, entityName, nameOfPropertyInCoreData, value, [NSNumber class], [value class]];
                    }
                }
                else if ((attributeType == NSBooleanAttributeType) && (![value isKindOfClass:[NSNumber class]])) {
                    
                    if ([value respondsToSelector:@selector(boolValue)]) {
                        value = [NSNumber numberWithBool:[value boolValue]];
                    }
                    else {
                        [NSException raise:PKInvalidAttributeValueException format:PKInvalidAttributeValueExceptionFormat, entityName, nameOfPropertyInCoreData, value, [NSNumber class], [value class]];
                    }
                }
                else if (((attributeType == NSDoubleAttributeType) || (attributeType == NSFloatAttributeType) || attributeType == NSDecimalAttributeType) && (![value isKindOfClass:[NSNumber class]])) {
                    
                    if ([value respondsToSelector:@selector(doubleValue)]) {
                        value = [NSNumber numberWithDouble:[value doubleValue]];
                    }
                    else {
                        [NSException raise:PKInvalidAttributeValueException format:PKInvalidAttributeValueExceptionFormat, entityName, nameOfPropertyInCoreData, value, [NSNumber class], [value class]];
                    }
                }
                else if ((attributeType == NSDateAttributeType) && (![value isKindOfClass:[NSDate class]])) {
                    
                    [NSException raise:PKInvalidAttributeValueException format:PKInvalidAttributeValueExceptionFormat, entityName, nameOfPropertyInCoreData, value, [NSDate class], [value class]];
                }
            }
            else if (![propertyDescription isOptional] && ![strongSelf valueForKey:nameOfPropertyInCoreData]) {
                
                 [NSException raise:PKInvalidAttributeValueException format:@"“%@.%@” expected to not be null", entityName, nameOfPropertyInCoreData];
            }
            
            [strongSelf setValue:value forKey:nameOfPropertyInCoreData];
        }
        
        //
        // RELATIONSHIPS
        //
        else if ([propertyDescription isKindOfClass:[NSRelationshipDescription class]]) {
            
            NSRelationshipDescription *relationshipDescription = (NSRelationshipDescription *)propertyDescription;
            NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:[[relationshipDescription destinationEntity] name]];
            [fetchRequest setFetchLimit:1];
            
            //
            // TO-MANY RELATIONSHIPS
            //
            if ([relationshipDescription isToMany]) {
                
                DBList *recordList = [bindToThisDBRecord objectForKey:nameOfPropertyInCoreData];
                
                // Make sure the DBRecord implements this property and that it is implemented as a DBList.
                if (recordList && ![recordList isKindOfClass:[DBList class]]) {
                    [NSException raise:PKInvalidAttributeValueException format:PKInvalidAttributeValueExceptionFormat, entityName, nameOfPropertyInCoreData, recordList, [DBList class], [recordList class]];
                }
                
                // Create an array that is essentially a copy of the DBList.
                // Assume that the DBList is a list of NSStrings. If any value within the list is not an NSString, perhaps if responds to stringValue, and if not, raise an exception.
                NSMutableArray *recordIdentifiers = [[NSMutableArray alloc] init];
                for (id value in [recordList values]) {
                    
                    if (![value isKindOfClass:[NSString class]]) {
                        
                        if ([value respondsToSelector:@selector(stringValue)]) {
                            [recordIdentifiers addObject:[value stringValue]];
                        }
                        else {
                            [NSException raise:PKInvalidAttributeValueException format:PKInvalidAttributeValueExceptionFormat, entityName, nameOfPropertyInCoreData, value, [NSString class], [value class]];
                        }
                    }
                    else {
                        [recordIdentifiers addObject:value];
                    }
                }
                
                // REMOVING RELATIONSHIPS
                // Iterate through this NSMO's relationship set. If the DBRecord's DBList doesn't contain the related object's syncId string, then perhaps we need sever this NSMO's relationship to that NSMO.
                NSMutableSet *relatedObjects = [strongSelf mutableSetValueForKey:nameOfPropertyInCoreData];
                NSMutableSet *unrelatedObjects = [[NSMutableSet alloc] init];
                for (NSManagedObject *relatedObject in relatedObjects) {
                    
                    if (![recordIdentifiers containsObject:[relatedObject valueForKey:syncAttributeName]]) {
                        [unrelatedObjects addObject:relatedObject];
                    }
                }
                [relatedObjects minusSet:unrelatedObjects];
                
                // ADDING RELATIONSHIPS
                // Iterate through the DBRecord's DBList's string values representing relationships. Query Core Data for each object. If the object is found, and this NSMO doesn't have a relationship to that object, give it a relationship to that object.
                for (NSString *identifier in recordIdentifiers) {
                    
                    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"%K == %@", syncAttributeName, identifier]];
                    [fetchRequest setIncludesPropertyValues:NO];
                    
                    NSError *error = nil;
                    NSArray *managedObjects = [strongSelf.managedObjectContext executeFetchRequest:fetchRequest error:&error];
                    
                    if (managedObjects) {
                        
                        if ([managedObjects count] == 1) {
                            NSManagedObject *relatedObject = managedObjects[0];
                            if (![relatedObjects containsObject:relatedObject]) {
                                [relatedObjects addObject:relatedObject];
                            }
                        }
                    }
                    else {
                        NSLog(@"Error executing fetch request: %@", error);
                    }
                };
            }
            
            //
            // TO-ONE RELATIONSHIPS
            //
            else {
                
                id syncIdOfRelatedObject = [bindToThisDBRecord objectForKey:nameOfPropertyInCoreData];
                
                if (syncIdOfRelatedObject) {
                    
                    if (![syncIdOfRelatedObject isKindOfClass:[NSString class]]) {
                        if ([syncIdOfRelatedObject respondsToSelector:@selector(stringValue)]) {
                            syncIdOfRelatedObject = [syncIdOfRelatedObject stringValue];
                        } else {
                            [NSException raise:PKInvalidAttributeValueException format:PKInvalidAttributeValueExceptionFormat, entityName, nameOfPropertyInCoreData, syncIdOfRelatedObject, [NSString class], [syncIdOfRelatedObject class]];
                        }
                    }
                    
                    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"%K == %@", syncAttributeName, syncIdOfRelatedObject]];
                    NSError *error = nil;
                    NSArray *managedObjects = [strongSelf.managedObjectContext executeFetchRequest:fetchRequest error:&error];
                    if (managedObjects) {
                        
                        if ([managedObjects count] == 1) {
                            
                            NSManagedObject *relatedObject = managedObjects[0];
                            
                            if (![[strongSelf valueForKey:nameOfPropertyInCoreData] isEqual:relatedObject]) {
                                [strongSelf setValue:relatedObject forKey:nameOfPropertyInCoreData];
                            }
                        }
                    }
                    else {
                        NSLog(@"Error executing fetch request: %@", error);
                    }
                }
                else {
                    [strongSelf setValue:nil forKey:nameOfPropertyInCoreData];
                }
            }
        }
    }];
}
@end
