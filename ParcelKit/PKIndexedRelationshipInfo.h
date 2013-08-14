//
//  PKIndexedRelationshipInfo.h
//  ParcelKit
//
//  Created by Phillip Harris on 8/13/13.
//  Copyright (c) 2013 Overcommitted, LLC. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface PKIndexedRelationshipInfo : NSObject
@property (nonatomic, strong) NSString *parentEntity;
@property (nonatomic, strong) NSString *toManyRel;
@property (nonatomic, strong) NSString *childEntity;
@property (nonatomic, strong) NSString *inverseRel;
@property (nonatomic, strong) NSString *indexName;
@end
